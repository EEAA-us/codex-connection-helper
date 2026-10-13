using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Web.Script.Serialization;

// A fixed-upstream loopback relay. It declines WebSocket upgrade so Codex can
// fall back to HTTP, and relays only Responses/model routes. No payload logging.
public sealed class CodexHttpBridge : IDisposable {
    readonly TcpListener listener;
    readonly HttpClient client;
    readonly Uri upstream;
    readonly string localToken;
    readonly string upstreamKey;
    readonly CancellationTokenSource lifetime = new CancellationTokenSource();
    readonly SemaphoreSlim slots = new SemaphoreSlim(16);
    static readonly object diagnosticLock = new object();
    public string DiagnosticPath { get; set; }
    public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
    public CodexHttpBridge(string url, string key, string token) {
        Uri parsed;
        if (!Uri.TryCreate(url, UriKind.Absolute, out parsed) || parsed.Scheme != "https" || !String.IsNullOrEmpty(parsed.UserInfo) || !String.IsNullOrEmpty(parsed.Query) || !String.IsNullOrEmpty(parsed.Fragment)) throw new ArgumentException("Invalid upstream endpoint");
        if (String.IsNullOrEmpty(key) || String.IsNullOrEmpty(token) || token.Length < 32) throw new ArgumentException("Missing bridge credentials");
        upstream = new Uri(url.TrimEnd('/') + "/"); upstreamKey = key; localToken = token;
        client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false });
        client.Timeout = Timeout.InfiniteTimeSpan;
        listener = new TcpListener(IPAddress.Loopback, 0); listener.Start(16);
    }
    public void Start() { Task.Run((Func<Task>)Accept); }
    async Task Accept() {
        while (!lifetime.IsCancellationRequested) {
            TcpClient socket;
            try { socket = await listener.AcceptTcpClientAsync().ConfigureAwait(false); }
            catch { if (lifetime.IsCancellationRequested) return; continue; }
            if (!slots.Wait(0)) { socket.Close(); continue; }
            Dispatch(socket);
        }
    }
    void Dispatch(TcpClient socket) { Task.Run(async delegate { try { await Serve(socket).ConfigureAwait(false); } catch { } finally { socket.Close(); slots.Release(); } }); }
    static async Task<string> Line(Stream stream, CancellationToken cancel) {
        var bytes = new List<byte>(); var one = new byte[1];
        while (bytes.Count < 16384) {
            if (await stream.ReadAsync(one, 0, 1, cancel).ConfigureAwait(false) == 0) throw new IOException("Closed request");
            if (one[0] == 10) return Encoding.ASCII.GetString(bytes.ToArray()).TrimEnd('\r');
            bytes.Add(one[0]);
        }
        throw new IOException("Header too large");
    }
    static bool TokenEqual(string a, string b) {
        var x = Encoding.UTF8.GetBytes(a ?? ""); var y = Encoding.UTF8.GetBytes(b ?? "");
        int mismatch = x.Length ^ y.Length;
        for (int i = 0; i < Math.Max(x.Length, y.Length); i++) mismatch |= (i < x.Length ? x[i] : 0) ^ (i < y.Length ? y[i] : 0);
        return mismatch == 0;
    }
    static async Task Reply(Stream stream, int status, string reason, string text, CancellationToken cancel) {
        byte[] body = Encoding.UTF8.GetBytes(text);
        byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + " " + reason + "\r\nContent-Type: application/json\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(header, 0, header.Length, cancel).ConfigureAwait(false);
        await stream.WriteAsync(body, 0, body.Length, cancel).ConfigureAwait(false);
    }
    // Do not infer success from text, silence, EOF or a timer. Some Responses
    // gateways finish with the legacy [DONE] marker; repair that only after a
    // real response identity and every announced, fully finished output item.
    sealed class ResponsesState {
        const int MaxRetained = 4194304;
        readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = MaxRetained };
        readonly Dictionary<int,string> added = new Dictionary<int,string>();
        readonly Dictionary<int,Dictionary<string,object>> finished = new Dictionary<int,Dictionary<string,object>>();
        Dictionary<string,object> created;
        int retained;
        bool usable = true;
        public bool End, Completed, Done, Normalized;
        public int OutputCount { get { return finished.Count; } }
        static Dictionary<string,object> Object(object o) { return o as Dictionary<string,object>; }
        static object Value(Dictionary<string,object> o,string key) { object v;return o != null && o.TryGetValue(key,out v) ? v : null; }
        static string Text(Dictionary<string,object> o,string key) { return Value(o,key) as string; }
        public void IgnoreFrame() { usable = false; }
        public string Observe(byte[] raw) {
            var data = new StringBuilder();
            foreach(string line in Encoding.UTF8.GetString(raw).Split('\n')) {
                string part = line.TrimEnd('\r');
                if (!part.StartsWith("data:",StringComparison.Ordinal)) continue;
                part = part.Substring(5); if(part.StartsWith(" ",StringComparison.Ordinal)) part = part.Substring(1);
                if(data.Length > 0) data.Append('\n');data.Append(part);
            }
            if(data.Length == 0) return null;
            if(data.ToString() == "[DONE]") {
                Done = true; End = true;
                if(!usable || Completed || created == null || added.Count == 0 || added.Count != finished.Count) return null;
                var output = new List<object>();bool substantive = false;
                for(int i=0;i<added.Count;i++) {
                    Dictionary<string,object> item;
                    if(!finished.TryGetValue(i,out item)) return null;
                    string kind = Text(item,"type");
                    if(Value(item,"status") != null && Text(item,"status") != "completed") return null;
                    if(kind == "message") {
                        if(Text(item,"role") != "assistant" || Text(item,"status") != "completed") return null;
                        var content = Value(item,"content") as object[];
                        if(content == null || content.Length == 0) return null;
                        foreach(object p in content) {
                            var part = Object(p);string type = Text(part,"type");
                            if(type != "output_text" && type != "refusal") return null;
                            if(!(Value(part,type == "refusal" ? "refusal" : "text") is string)) return null;
                        }
                        substantive = true;
                    } else if(kind == "function_call" || kind == "custom_tool_call") {
                        if(Text(item,"status") != "completed" || String.IsNullOrEmpty(Text(item,"call_id")) || String.IsNullOrEmpty(Text(item,"name")) || !(Value(item,kind == "function_call" ? "arguments" : "input") is string)) return null;
                        substantive = true;
                    } else if(kind != "reasoning") return null;
                    output.Add(item);
                }
                if(!substantive) return null;
                var response = new Dictionary<string,object>(created);
                response["status"] = "completed";response["output"] = output;
                // Usage is unavailable on this broken stream; never invent tokens.
                response["usage"] = null;
                string completion;
                try { completion = json.Serialize(new Dictionary<string,object> { {"type","response.completed"},{"response",response} }); }
                catch { usable = false;return null; }
                Normalized = true;Completed = true;
                return "event: response.completed\ndata: " + completion + "\n\n";
            }
            Dictionary<string,object> e;
            try { e = Object(json.DeserializeObject(data.ToString())); } catch { usable = false;return null; }
            if(e == null) { usable = false;return null; }
            string typeName = Text(e,"type");
            if(typeName == "response.completed") { End = true;Completed = Text(Object(Value(e,"response")),"status") == "completed";usable = false;return null; }
            if(typeName == "response.failed" || typeName == "response.incomplete" || typeName == "error") { End = true;usable = false;return null; }
            if(typeName == null || typeName == "response.error" || typeName == "response.cancelled" || typeName == "response.canceled") { usable = false;return null; }
            if(!usable) return null;
            if(typeName == "response.created") {
                if(created != null) { usable = false;return null; }
                created = Object(Value(e,"response"));
                if(created == null || String.IsNullOrEmpty(Text(created,"id")) || Text(created,"object") != "response" || (Text(created,"status") != "in_progress" && Text(created,"status") != "queued") || Value(created,"error") != null || Value(created,"incomplete_details") != null) usable = false;
            } else if(typeName == "response.output_item.added" || typeName == "response.output_item.done") {
                object indexValue = Value(e,"output_index");var item = Object(Value(e,"item"));
                if(!(indexValue is int) || (int)indexValue < 0 || (int)indexValue > 4095 || item == null || String.IsNullOrEmpty(Text(item,"id"))) { usable = false;return null; }
                int index = (int)indexValue;string id = Text(item,"id"), previous;
                if(typeName == "response.output_item.added") {
                    if(added.ContainsKey(index)) { usable = false;return null; }
                    added[index] = id;
                } else {
                    if(!added.TryGetValue(index,out previous) || previous != id || finished.ContainsKey(index)) { usable = false;return null; }
                    retained += data.Length;
                    if(retained > MaxRetained) { usable = false;finished.Clear();return null; }
                    finished[index] = item;
                }
            }
            return null;
        }
    }
    static async Task Chunk(Stream stream,byte[] data,CancellationToken cancel) {
        if(data.Length == 0) return;
        byte[] header=Encoding.ASCII.GetBytes(data.Length.ToString("X")+"\r\n");
        await stream.WriteAsync(header,0,header.Length,cancel).ConfigureAwait(false);
        await stream.WriteAsync(data,0,data.Length,cancel).ConfigureAwait(false);
        await stream.WriteAsync(new byte[]{13,10},0,2,cancel).ConfigureAwait(false);
        await stream.FlushAsync(cancel).ConfigureAwait(false);
    }
    static async Task RelayResponses(Stream input,Stream output,ResponsesState state,CancellationToken cancel) {
        byte[] buffer=new byte[16384];int amount,lineLength=0;bool oversized=false;
        using(var frame=new MemoryStream()) {
            while((amount=await input.ReadAsync(buffer,0,buffer.Length,cancel).ConfigureAwait(false)) != 0) {
                int start=0;
                for(int i=0;i<amount;i++) {
                    bool boundary=false;
                    if(buffer[i] == 10) { boundary=lineLength == 0;lineLength=0; }
                    else if(buffer[i] != 13) lineLength++;
                    if(!boundary) continue;
                    frame.Write(buffer,start,i-start+1);start=i+1;
                    byte[] raw=frame.ToArray();frame.SetLength(0);
                    string repair=oversized ? null : state.Observe(raw);oversized=false;
                    if(repair != null) await Chunk(output,Encoding.UTF8.GetBytes(repair),cancel).ConfigureAwait(false);
                    await Chunk(output,raw,cancel).ConfigureAwait(false);
                    if(state.End) return;
                }
                frame.Write(buffer,start,amount-start);
                if(frame.Length > 4194304) {
                    state.IgnoreFrame();oversized=true;
                    await Chunk(output,frame.ToArray(),cancel).ConfigureAwait(false);frame.SetLength(0);
                }
            }
            // Preserve a truncated last frame, but it cannot establish success.
            await Chunk(output,frame.ToArray(),cancel).ConfigureAwait(false);
        }
    }
    void Diagnostic(int status,ResponsesState state,string result) {
        if(String.IsNullOrEmpty(DiagnosticPath)) return;
        try {
            string line="{\"utc\":\""+DateTime.UtcNow.ToString("o")+"\",\"http_status\":"+status+",\"result\":\""+result+"\",\"completed\":"+(state != null && state.Completed ? "true" : "false")+",\"normalized\":"+(state != null && state.Normalized ? "true" : "false")+",\"done_marker\":"+(state != null && state.Done ? "true" : "false")+",\"output_items\":"+(state == null ? 0 : state.OutputCount)+"}\n";
            lock(diagnosticLock) {
                if(File.Exists(DiagnosticPath) && new FileInfo(DiagnosticPath).Length > 1048576) File.WriteAllText(DiagnosticPath,"");
                File.AppendAllText(DiagnosticPath,line,Encoding.UTF8);
            }
        } catch { }
    }
    async Task Serve(TcpClient socket) {
        using (socket)
        using (var limit = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token)) {
            limit.CancelAfter(TimeSpan.FromSeconds(30)); var cancel = limit.Token; Stream stream = socket.GetStream();
            string[] request = (await Line(stream, cancel).ConfigureAwait(false)).Split(' ');
            if (request.Length != 3) return;
            var headers = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            int total = 0;
            for (;;) {
                string line = await Line(stream, cancel).ConfigureAwait(false); if (line.Length == 0) break;
                total += line.Length; if (total > 65536) return;
                int colon = line.IndexOf(':'); if (colon <= 0) return;
                string name = line.Substring(0, colon).Trim(); if (headers.ContainsKey(name)) return;
                headers[name] = line.Substring(colon + 1).Trim();
            }
            string origin; if (headers.TryGetValue("Origin", out origin)) { await Reply(stream,403,"Forbidden","{\"error\":\"Browser origins are not allowed\"}",cancel); return; }
            string auth; if (!headers.TryGetValue("Authorization", out auth) || !TokenEqual(auth,"Bearer " + localToken)) { await Reply(stream,401,"Unauthorized","{\"error\":\"Invalid local bridge credential\"}",cancel); return; }
            limit.CancelAfter(TimeSpan.FromMinutes(20));
            string path = request[1];
            if (path != "/v1/responses" && path != "/v1/responses/compact" && path != "/v1/models") { await Reply(stream,404,"Not Found","{\"error\":\"Unsupported bridge route\"}",cancel); return; }
            if (request[0] == "GET" && path == "/v1/responses") { await Reply(stream,426,"Upgrade Required","{\"error\":{\"message\":\"Use HTTP POST Responses; WebSocket is unavailable\"}}",cancel); return; }
            if (request[0] != "POST" && !(request[0] == "GET" && path == "/v1/models")) { await Reply(stream,405,"Method Not Allowed","{\"error\":\"Unsupported method\"}",cancel); return; }
            string lengthText, transfer;
            if (headers.TryGetValue("Transfer-Encoding",out transfer)) { await Reply(stream,400,"Bad Request","{\"error\":\"Chunked request bodies are unsupported\"}",cancel); return; }
            long length = 0;
            if (headers.TryGetValue("Content-Length",out lengthText) && (!Int64.TryParse(lengthText,out length) || length < 0 || length > 33554432)) { await Reply(stream,413,"Payload Too Large","{\"error\":\"Request exceeds bridge limit\"}",cancel); return; }
            string expect;
            if (headers.TryGetValue("Expect",out expect) && expect.Equals("100-continue",StringComparison.OrdinalIgnoreCase)) {
                byte[] interim = Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n"); await stream.WriteAsync(interim,0,interim.Length,cancel).ConfigureAwait(false);
            }
            byte[] body = new byte[(int)length]; int read = 0;
            while (read < body.Length) { int amount = await stream.ReadAsync(body, read, body.Length-read,cancel).ConfigureAwait(false); if (amount == 0) return; read += amount; }
            using (var message = new HttpRequestMessage(new HttpMethod(request[0]),new Uri(upstream,path.Substring(4).TrimStart('/')))) {
                message.Headers.TryAddWithoutValidation("Authorization","Bearer " + upstreamKey);
                message.Headers.TryAddWithoutValidation("Accept","text/event-stream, application/json");
                if (request[0] == "POST") {
                    message.Content = new ByteArrayContent(body); string type;
                    message.Content.Headers.TryAddWithoutValidation("Content-Type",headers.TryGetValue("Content-Type",out type) ? type : "application/json");
                    string coding; if (headers.TryGetValue("Content-Encoding",out coding)) message.Content.Headers.TryAddWithoutValidation("Content-Encoding",coding);
                }
                HttpResponseMessage response = null;
                try { response = await client.SendAsync(message,HttpCompletionOption.ResponseHeadersRead,cancel).ConfigureAwait(false); }
                catch { }
                if (response == null) { await Reply(stream,502,"Bad Gateway","{\"error\":{\"message\":\"Upstream HTTP connection failed\"}}",cancel); return; }
                using (response) {
                    var output = new StringBuilder("HTTP/1.1 ").Append((int)response.StatusCode).Append(" Upstream\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n");
                    foreach (var h in response.Content.Headers) if (h.Key.Equals("Content-Type",StringComparison.OrdinalIgnoreCase) || h.Key.Equals("Content-Encoding",StringComparison.OrdinalIgnoreCase)) output.Append(h.Key).Append(": ").Append(String.Join(", ",h.Value)).Append("\r\n");
                    foreach (var h in response.Headers) if (h.Key.Equals("Retry-After",StringComparison.OrdinalIgnoreCase)) output.Append(h.Key).Append(": ").Append(String.Join(", ",h.Value)).Append("\r\n");
                    byte[] begin = Encoding.ASCII.GetBytes(output.Append("\r\n").ToString()); await stream.WriteAsync(begin,0,begin.Length,cancel).ConfigureAwait(false);
                    using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false)) {
                        var type = response.Content.Headers.ContentType;
                        bool isResponses = path == "/v1/responses" && response.IsSuccessStatusCode && type != null && type.MediaType.Equals("text/event-stream",StringComparison.OrdinalIgnoreCase) && response.Content.Headers.ContentEncoding.Count == 0;
                        ResponsesState state = isResponses ? new ResponsesState() : null;
                        try {
                            if(isResponses) await RelayResponses(input,stream,state,cancel).ConfigureAwait(false);
                            else {
                                byte[] buffer = new byte[16384]; int amount;
                                while ((amount=await input.ReadAsync(buffer,0,buffer.Length,cancel).ConfigureAwait(false)) != 0) {
                                    byte[] raw=new byte[amount];Buffer.BlockCopy(buffer,0,raw,0,amount);
                                    await Chunk(stream,raw,cancel).ConfigureAwait(false);
                                }
                            }
                            Diagnostic((int)response.StatusCode,state,isResponses ? (state.Normalized ? "completed_from_explicit_done" : state.Completed ? "completed" : state.End ? "terminal_without_completion" : "eof_without_completion") : "passthrough");
                        } catch {
                            Diagnostic((int)response.StatusCode,state,state != null && state.Completed ? "client_closed_after_completion" : cancel.IsCancellationRequested ? "cancelled_or_timeout" : "transport_error");throw;
                        }
                        byte[] end=Encoding.ASCII.GetBytes("0\r\n\r\n");await stream.WriteAsync(end,0,end.Length,cancel).ConfigureAwait(false);
                    }
                }
            }
        }
    }
    public void Dispose() { lifetime.Cancel();listener.Stop();client.Dispose(); }
}

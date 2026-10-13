using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

public sealed class CodexApiProbeResult {
    public bool Success { get; set; }
    public string Code { get; set; }
    public int HttpStatus { get; set; }
    public long ElapsedMs { get; set; }
    public long HeadersMs { get; set; }
    public long FirstTextMs { get; set; }
}

// Consumes the same loopback Responses transport used by the launcher.
// No response text, identifiers, credentials or provider error messages are returned.
public sealed class CodexApiProbe : IDisposable {
    const int Limit = 1024 * 1024;
    readonly CancellationTokenSource cancel = new CancellationTokenSource();
    readonly Stopwatch elapsed = new Stopwatch();
    volatile string stage = "starting_bridge";
    public string Stage { get { return stage; } }
    public long ElapsedMs { get { return elapsed.ElapsedMilliseconds; } }
    readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = Limit };
    public bool IsCancelled { get { return cancel.IsCancellationRequested; } }
    public void Cancel() { cancel.Cancel(); }
    static Dictionary<string,object> Obj(object value) { return value as Dictionary<string,object>; }
    static object Get(Dictionary<string,object> value,string name) { object found;return value != null && value.TryGetValue(name,out found) ? found : null; }
    static string Str(Dictionary<string,object> value,string name) { return Get(value,name) as string; }
    static bool HasText(Dictionary<string,object> response) {
        if(Str(response,"object") != "response" || Str(response,"status") != "completed" || String.IsNullOrWhiteSpace(Str(response,"id")) || Get(response,"error") != null || Get(response,"incomplete_details") != null) return false;
        var output=Get(response,"output") as object[];
        if(output == null) return false;
        bool found=false;
        foreach(var value in output) {
            var item=Obj(value);
            var status=Str(item,"status");
            if(status == "in_progress" || status == "incomplete" || status == "failed") return false;
            if(Str(item,"type") != "message" || Str(item,"role") != "assistant" || Str(item,"status") != "completed") continue;
            var parts=Get(item,"content") as object[];
            if(parts == null) continue;
            foreach(var partValue in parts) {
                var part=Obj(partValue);
                if(Str(part,"type") == "output_text" && !String.IsNullOrWhiteSpace(Str(part,"text"))) found=true;
            }
        }
        return found;
    }
    string Event(string data) {
        if(data == "[DONE]") return "missing_completion";
        Dictionary<string,object> e;
        try { e=Obj(json.DeserializeObject(data)); } catch { return "invalid_response"; }
        if(e == null) return "invalid_response";
        var type=Str(e,"type");
        if(type == "response.created" || type == "response.in_progress") stage="generating";
        if(type == "response.output_text.delta" && !String.IsNullOrWhiteSpace(Str(e,"delta"))) stage="receiving_text";
        if(type == "response.failed" || type == "error") return "provider_error";
        if(type == "response.incomplete") return "incomplete";
        if(type == "response.completed") return HasText(Obj(Get(e,"response"))) ? "ok" : "empty_or_invalid_completion";
        return null;
    }
    public async Task<CodexApiProbeResult> RunAsync(string address,string token,string requestBody,int timeoutSeconds) {
        var result=new CodexApiProbeResult { Code="transport_error", HeadersMs=-1, FirstTextMs=-1 };
        elapsed.Restart();stage="waiting_headers";
        try {
            Uri uri;
            if(!Uri.TryCreate(address,UriKind.Absolute,out uri) || uri.Scheme != "http" || !uri.IsLoopback || uri.AbsolutePath != "/v1/responses" || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0) {
                result.Code="invalid_local_endpoint";return result;
            }
            using(var deadline=CancellationTokenSource.CreateLinkedTokenSource(cancel.Token)) {
                deadline.CancelAfter(TimeSpan.FromSeconds(Math.Max(1,Math.Min(45,timeoutSeconds))));
                using(var client=new HttpClient(new HttpClientHandler { UseProxy=false,AllowAutoRedirect=false,UseCookies=false,AutomaticDecompression=DecompressionMethods.GZip|DecompressionMethods.Deflate })) {
                    client.Timeout=Timeout.InfiniteTimeSpan;
                    using(var request=new HttpRequestMessage(HttpMethod.Post,uri)) {
                        request.Headers.Authorization=new AuthenticationHeaderValue("Bearer",token);
                        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
                        request.Headers.TryAddWithoutValidation("User-Agent","CodexLauncher/0.1");
                        request.Content=new StringContent(requestBody,Encoding.UTF8,"application/json");
                        using(var response=await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,deadline.Token).ConfigureAwait(false)) {
                            result.HttpStatus=(int)response.StatusCode;
                            result.HeadersMs=elapsed.ElapsedMilliseconds;stage="waiting_reply";
                            if(!response.IsSuccessStatusCode) { result.Code="http_error";return result; }
                            if(response.Content.Headers.ContentType == null || !response.Content.Headers.ContentType.MediaType.Equals("text/event-stream",StringComparison.OrdinalIgnoreCase)) {
                                result.Code="unsupported_protocol";return result;
                            }
                            using(var stream=await response.Content.ReadAsStreamAsync().ConfigureAwait(false)) {
                                var interrupted=new TaskCompletionSource<bool>();
                                using(var registration=deadline.Token.Register(()=>interrupted.TrySetResult(true))) {
                                byte[] buffer=new byte[4096];char[] chars=new char[Encoding.UTF8.GetMaxCharCount(4096)];
                                var decoder=new UTF8Encoding(false,true).GetDecoder();
                                var line=new StringBuilder();var data=new StringBuilder();int total=0;
                                for(;;) {
                                    deadline.Token.ThrowIfCancellationRequested();
                                    var reading=stream.ReadAsync(buffer,0,buffer.Length,deadline.Token);
                                    if(await Task.WhenAny(reading,interrupted.Task).ConfigureAwait(false) != reading) {
                                        GC.KeepAlive(reading.ContinueWith(t=>GC.KeepAlive(t.Exception),TaskContinuationOptions.OnlyOnFaulted));
                                        throw new OperationCanceledException(deadline.Token);
                                    }
                                    int size=await reading.ConfigureAwait(false);
                                    deadline.Token.ThrowIfCancellationRequested();
                                    if(size == 0) { result.Code="missing_completion";return result; }
                                    total+=size;if(total > Limit) { result.Code="response_too_large";return result; }
                                    int length=decoder.GetChars(buffer,0,size,chars,0,false);
                                    for(int i=0;i<length;i++) {
                                        if(chars[i] != '\n') { line.Append(chars[i]);continue; }
                                        var current=line.ToString().TrimEnd('\r');line.Clear();
                                        if(current.Length == 0 && data.Length > 0) {
                                            var code=Event(data.ToString());data.Clear();
                                            if((stage == "receiving_text" || code == "ok") && result.FirstTextMs < 0) result.FirstTextMs=elapsed.ElapsedMilliseconds;
                                            if(code != null) { result.Code=code;result.Success=code == "ok";return result; }
                                        } else if(current.StartsWith("data:",StringComparison.Ordinal)) {
                                            if(data.Length > 0)data.Append('\n');
                                            var payload=current.Substring(5);if(payload.StartsWith(" ",StringComparison.Ordinal))payload=payload.Substring(1);
                                            data.Append(payload);
                                        }
                                    }
                                }
                                }
                            }
                        }
                    }
                }
            }
        } catch(OperationCanceledException) { result.Code=cancel.IsCancellationRequested ? "cancelled" : "timeout";return result; }
          catch(DecoderFallbackException) { result.Code="invalid_response";return result; }
          catch { result.Code="transport_error";return result; }
        finally { elapsed.Stop();result.ElapsedMs=elapsed.ElapsedMilliseconds;stage="finished"; }
    }
    public void Dispose() { cancel.Cancel();cancel.Dispose(); }
}

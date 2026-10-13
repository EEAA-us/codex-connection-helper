using System;
using System.IO;
using System.Text;
using System.Collections;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

// No provider response bodies, credentials, prompts, or reference bytes are logged.
public sealed class CodexImageTools : IDisposable {
    const int Limit = 48 * 1024 * 1024;
    readonly Dictionary<string,object> config;
    readonly bool testHttp;
    readonly bool requireSession;
    readonly ConcurrentDictionary<string,CancellationTokenSource> calls = new ConcurrentDictionary<string,CancellationTokenSource>();
    readonly object outputLock = new object();
    readonly CancellationTokenSource lifetime = new CancellationTokenSource();
    readonly SemaphoreSlim single = new SemaphoreSlim(1,1);
    public volatile string Stage = "idle";
    public string ActiveJobId = "";
    static JavaScriptSerializer Json() { return new JavaScriptSerializer { MaxJsonLength=Limit, RecursionLimit=40 }; }
    public static string Serialize(object x) { return Json().Serialize(x); }
    static Dictionary<string,object> Obj(object x) { return x as Dictionary<string,object>; }
    static string Str(Dictionary<string,object> x,string key,string fallback="") { object v; return x!=null && x.TryGetValue(key,out v) && v!=null ? Convert.ToString(v) : fallback; }
    static int Num(Dictionary<string,object> x,string key,int fallback) { int n; return Int32.TryParse(Str(x,key),out n) ? n : fallback; }
    static Dictionary<string,object> Map(params object[] pairs) { var d=new Dictionary<string,object>();for(int i=0;i<pairs.Length;i+=2)d[(string)pairs[i]]=pairs[i+1];return d; }
    public CodexImageTools(string json,bool requireApiSession,bool allowLoopbackTestHttp=false) {
        config=Obj(Json().DeserializeObject(json));requireSession=requireApiSession;testHttp=allowLoopbackTestHttp;
        if(config==null)throw new ArgumentException("Invalid image configuration");
        ValidateUrl(new Uri(Str(config,"base_url")),false);
        if(Str(config,"model")=="" || Str(config,"key")=="")throw new ArgumentException("Image model and key required");
        if(Array.IndexOf(new[]{"images_auto","images_sync","cctq_async","responses_image"},Str(config,"protocol"))<0)throw new ArgumentException("Unsupported image protocol");
        if(!Path.IsPathRooted(Str(config,"output_dir")) || !Path.IsPathRooted(Str(config,"jobs_dir")))throw new ArgumentException("Absolute image directories required");
    }
    void CheckSession() {
        if(!requireSession)return;
        var state=Obj(Json().DeserializeObject(File.ReadAllText(Str(config,"switch_file"),Encoding.UTF8)));
        if(Str(state,"active")!="True" || Str(state,"phase")!="ready" || Str(state,"image_runtime_path")!=Str(config,"runtime_path"))throw new InvalidOperationException("Image API session is inactive");
        using(var sha=SHA256.Create())using(var f=File.OpenRead(Str(config,"auth_file"))) {
            if(BitConverter.ToString(sha.ComputeHash(f)).Replace("-","")!=Str(state,"active_auth_hash"))throw new InvalidOperationException("Image API session changed");
        }
    }
    static bool SameOrigin(Uri a,Uri b) { return a.Scheme==b.Scheme && a.IdnHost.Equals(b.IdnHost,StringComparison.OrdinalIgnoreCase) && a.Port==b.Port; }
    void ValidateUrl(Uri u,bool download) {
        if(!u.IsAbsoluteUri || u.UserInfo!="" || u.Fragment!="" || (u.Scheme!="https" && !(testHttp && u.Scheme=="http" && u.IsLoopback)))throw new InvalidOperationException("Unsafe image URL");
        if(download && !testHttp && (u.IsLoopback || u.HostNameType==UriHostNameType.IPv4 && (u.Host.StartsWith("10.") || u.Host.StartsWith("192.168.") || u.Host.StartsWith("169.254."))))throw new InvalidOperationException("Unsafe image download URL");
    }
    static string Seal(string value) { return Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(value),null,DataProtectionScope.CurrentUser)); }
    static string Open(string value) { return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(value),null,DataProtectionScope.CurrentUser)); }
    string JobPath(string id) { if(!System.Text.RegularExpressions.Regex.IsMatch(id,"^[a-f0-9]{32}$"))throw new ArgumentException("Invalid task ID");return Path.Combine(Str(config,"jobs_dir"),id+".json"); }
    void SaveJob(string id,Dictionary<string,object> job) {
        Directory.CreateDirectory(Str(config,"jobs_dir"));string path=JobPath(id),temp=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        try { File.WriteAllText(temp,Serialize(Map("version",1,"encrypted_task",Seal(Serialize(job)))),new UTF8Encoding(false));if(File.Exists(path))File.Replace(temp,path,null);else File.Move(temp,path); }
        finally { if(File.Exists(temp))File.Delete(temp); }
    }
    Dictionary<string,object> LoadJob(string id) { return Obj(Json().DeserializeObject(Open(Str(Obj(Json().DeserializeObject(File.ReadAllText(JobPath(id),Encoding.UTF8))),"encrypted_task")))); }
    public void Cancel() { lifetime.Cancel(); }
    static string ImageMime(byte[] b) {
        if(b.Length>=24 && b[0]==137 && b[1]==80 && b[2]==78 && b[3]==71 && b[4]==13 && b[5]==10 && b[6]==26 && b[7]==10)return "image/png";
        if(b.Length>=4 && b[0]==255 && b[1]==216 && b[2]==255)return "image/jpeg";
        if(b.Length>=12 && Encoding.ASCII.GetString(b,0,4)=="RIFF" && Encoding.ASCII.GetString(b,8,4)=="WEBP")return "image/webp";
        throw new InvalidDataException("Response is not a supported image");
    }
    async Task<byte[]> ReadLimited(HttpContent body,int limit,CancellationToken cancel) {
        if(body.Headers.ContentLength.HasValue && body.Headers.ContentLength.Value>limit)throw new InvalidDataException("Image response too large");
        using(var input=await body.ReadAsStreamAsync().ConfigureAwait(false))using(var output=new MemoryStream()) {
            // .NET Framework network streams may ignore the ReadAsync cancellation token.
            var interrupted=new TaskCompletionSource<bool>();
            using(var registration=cancel.Register(()=>interrupted.TrySetResult(true))) {
                var buffer=new byte[16384];
                for(;;) {
                    cancel.ThrowIfCancellationRequested();
                    var reading=input.ReadAsync(buffer,0,buffer.Length,cancel);
                    if(await Task.WhenAny(reading,interrupted.Task).ConfigureAwait(false)!=reading) {
                        GC.KeepAlive(reading.ContinueWith(t=>GC.KeepAlive(t.Exception),TaskContinuationOptions.OnlyOnFaulted));
                        throw new OperationCanceledException(cancel);
                    }
                    int n=await reading.ConfigureAwait(false);cancel.ThrowIfCancellationRequested();
                    if(n==0)break;if(output.Length+n>limit)throw new InvalidDataException("Image response too large");output.Write(buffer,0,n);
                }
                return output.ToArray();
            }
        }
    }
    async Task<Dictionary<string,object>> ReadJson(HttpResponseMessage response,CancellationToken cancel) {
        if(!response.IsSuccessStatusCode)throw new HttpRequestException("Image service HTTP "+(int)response.StatusCode);
        var type=response.Content.Headers.ContentType;
        if(type==null || type.MediaType.IndexOf("json",StringComparison.OrdinalIgnoreCase)<0)throw new InvalidDataException("Unsupported image response protocol");
        Dictionary<string,object> value;
        try { value=Obj(Json().DeserializeObject(Encoding.UTF8.GetString(await ReadLimited(response.Content,Limit,cancel).ConfigureAwait(false)))); }
        catch(OperationCanceledException){throw;}catch{throw new InvalidDataException("Invalid image JSON response");}
        if(value==null)throw new InvalidDataException("Invalid image response");return value;
    }
    HttpClient Client(Dictionary<string,object> cfg) {
        var handler=new HttpClientHandler { AllowAutoRedirect=false,UseCookies=false,UseProxy=Str(cfg,"network","system")!="direct",AutomaticDecompression=DecompressionMethods.GZip|DecompressionMethods.Deflate };
        return new HttpClient(handler) { Timeout=Timeout.InfiniteTimeSpan };
    }
    HttpRequestMessage Request(HttpMethod method,Uri url,string key) {
        ValidateUrl(url,false);var request=new HttpRequestMessage(method,url);
        if(key!="")request.Headers.Authorization=new AuthenticationHeaderValue("Bearer",key);return request;
    }
    Dictionary<string,object> Parameters(Dictionary<string,object> cfg,string prompt) {
        var body=Map("model",Str(cfg,"model"),"prompt",prompt,"n",1);
        foreach(var key in new[]{"size","quality","output_format","background"})if(Str(cfg,key)!="")body[key]=Str(cfg,key);
        if(Str(cfg,"protocol")=="cctq_async")body["async"]=true;return body;
    }
    HttpContent Body(Dictionary<string,object> cfg,string prompt,Dictionary<string,object> args,bool edit) {
        if(Str(cfg,"protocol")=="responses_image") {
            var input=new List<object>{Map("type","input_text","text",prompt)};
            if(edit) {
                object refs;var referencePaths=args.TryGetValue("reference_image_paths",out refs)?refs as IEnumerable:null;
                if(referencePaths==null || refs is string)throw new ArgumentException("Reference image paths required");int referenceCount=0;
                foreach(var value in referencePaths) {
                    string path=Convert.ToString(value);
                    if(++referenceCount>16 || !Path.IsPathRooted(path) || !File.Exists(path) || (File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)throw new ArgumentException("Reference image must be an existing local file (maximum 16)");
                    if(new FileInfo(path).Length>20*1024*1024)throw new ArgumentException("Reference image exceeds 20 MiB");
                    var bytes=File.ReadAllBytes(path);input.Add(Map("type","input_image","image_url","data:"+ImageMime(bytes)+";base64,"+Convert.ToBase64String(bytes)));
                }
                if(referenceCount==0)throw new ArgumentException("Reference image paths required");
            }
            return new StringContent(Serialize(Map("model",Str(cfg,"model"),"store",false,"stream",false,
                "input",new object[]{Map("role","user","content",input)},"tools",new object[]{Map("type","image_generation","action",edit?"edit":"generate")},
                "tool_choice",Map("type","image_generation"))),Encoding.UTF8,"application/json");
        }
        var body=Parameters(cfg,prompt);
        if(!edit)return new StringContent(Serialize(body),Encoding.UTF8,"application/json");
        object raw;var paths=args.TryGetValue("reference_image_paths",out raw) ? raw as IEnumerable : null;
        if(paths==null || raw is string)throw new ArgumentException("Reference image paths required");
        var multipart=new MultipartFormDataContent();int count=0;
        try {
            foreach(var pathValue in paths) {
                string path=Convert.ToString(pathValue);
                if(!Path.IsPathRooted(path) || !File.Exists(path) || (File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)throw new ArgumentException("Reference image must be an existing local file");
                if(new FileInfo(path).Length>20*1024*1024)throw new ArgumentException("Reference image exceeds 20 MiB");
                var bytes=File.ReadAllBytes(path);var content=new ByteArrayContent(bytes);content.Headers.ContentType=new MediaTypeHeaderValue(ImageMime(bytes));
                multipart.Add(content,"image[]","reference-"+(++count)+Path.GetExtension(path));
                if(count>16)throw new ArgumentException("Too many reference images");
            }
            if(count==0)throw new ArgumentException("Reference image paths required");
            foreach(var pair in body)multipart.Add(new StringContent(pair.Value is bool ? "true" : Convert.ToString(pair.Value)),pair.Key);
            return multipart;
        }catch{multipart.Dispose();throw;}
    }
    async Task<byte[]> Download(HttpClient client,Uri initial,Dictionary<string,object> cfg,CancellationToken cancel) {
        var origin=new Uri(Str(cfg,"base_url"));Uri url=initial;
        for(int redirect=0;redirect<=4;redirect++) {
            ValidateUrl(url,true);
            using(var request=Request(HttpMethod.Get,url,SameOrigin(origin,url)?Str(cfg,"key"):""))
            using(var response=await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,cancel).ConfigureAwait(false)) {
                int status=(int)response.StatusCode;
                if(status>=300 && status<400) {
                    var next=response.Headers.Location;if(next==null)throw new InvalidDataException("Invalid image redirect");url=new Uri(url,next);continue;
                }
                if(!response.IsSuccessStatusCode)throw new HttpRequestException("Image download HTTP "+status);
                var bytes=await ReadLimited(response.Content,32*1024*1024,cancel).ConfigureAwait(false);ImageMime(bytes);return bytes;
            }
        }throw new InvalidDataException("Too many image redirects");
    }
    async Task<Dictionary<string,object>> SaveResult(HttpClient client,Dictionary<string,object> response,Dictionary<string,object> cfg,string id,CancellationToken cancel) {
        object raw;var data=response.TryGetValue("data",out raw)?raw as IEnumerable:null;
        if(data==null || raw is string)throw new InvalidDataException("Image response has no images");
        var paths=new List<string>();var previews=new List<object>();int index=0;
        foreach(var item in data) {
            if(++index>4)throw new InvalidDataException("Unexpected image count");var entry=Obj(item);byte[] bytes;
            if(Str(entry,"b64_json")!="") { bytes=Convert.FromBase64String(Str(entry,"b64_json"));if(bytes.Length>32*1024*1024)throw new InvalidDataException("Image too large"); }
            else if(Str(entry,"url")!="")bytes=await Download(client,new Uri(new Uri(Str(cfg,"base_url")+"/"),Str(entry,"url")),cfg,cancel).ConfigureAwait(false);
            else throw new InvalidDataException("Image response has no image data");
            var mime=ImageMime(bytes);string extension=mime=="image/png"?".png":mime=="image/jpeg"?".jpg":".webp";
            string directory=Path.GetFullPath(Str(cfg,"output_dir"));Directory.CreateDirectory(directory);
            string path=Path.Combine(directory,"image-"+id+"-"+index+extension),partial=path+".partial";
            if(File.Exists(path)) { paths.Add(path);continue; }
            try { using(var file=new FileStream(partial,FileMode.CreateNew,FileAccess.Write,FileShare.None))file.Write(bytes,0,bytes.Length);File.Move(partial,path); }
            finally { if(File.Exists(partial))File.Delete(partial); }
            paths.Add(path);
            if(bytes.Length<=1024*1024)previews.Add(Map("type","image","data",Convert.ToBase64String(bytes),"mimeType",mime));
        }
        if(paths.Count==0)throw new InvalidDataException("Empty image response");
        return Map("status","completed","job_id",id,"paths",paths,"previews",previews,"message","Images saved locally. Render the absolute file paths in the conversation. Copy final project assets into the workspace when requested.");
    }
    Dictionary<string,object> Result(string state,string id,string message,bool resume) { return Map("status",state,"job_id",id,"message",message,"can_resume",resume); }
    static bool HasImages(Dictionary<string,object> value) { object data=null;var array=value!=null && value.TryGetValue("data",out data)?data as IEnumerable:null;if(array==null || data is string)return false;foreach(var item in array)if(Str(Obj(item),"b64_json")!="" || Str(Obj(item),"url")!="")return true;return false; }
    Dictionary<string,object> ResponseImages(Dictionary<string,object> value) {
        if(Str(value,"status")!="completed")throw new InvalidDataException("图片回复未完整结束，结果尚未确认；不会自动重新提交。");
        object raw;var output=value.TryGetValue("output",out raw)?raw as IEnumerable:null;var data=new List<object>();
        if(output!=null && !(raw is string))foreach(var item in output) {
            var call=Obj(item);if(Str(call,"type")=="image_generation_call" && Str(call,"result")!="") {
                if(Str(call,"status","completed")!="completed")throw new InvalidDataException("图片工具尚未完成。");
                data.Add(Map("b64_json",Str(call,"result")));
            }
        }
        if(data.Count==0)throw new InvalidDataException("此接口未返回 Responses 图片工具结果。请核对生图能力，或改用独立图片服务；普通聊天仍可使用。");
        return Map("data",data);
    }
    bool KnownTask(Dictionary<string,object> value,Dictionary<string,object> cfg,string taskId) {
        if(!System.Text.RegularExpressions.Regex.IsMatch(taskId,"^[A-Za-z0-9_-]{1,200}$"))return false;
        if(Str(cfg,"protocol")=="cctq_async" || Str(value,"object")=="image.task")return true;
        var poll=Str(value,"poll_url");if(poll=="")return false;
        Uri target;var expected=new Uri(Str(cfg,"base_url").TrimEnd('/')+"/images/tasks/"+Uri.EscapeDataString(taskId));
        return Uri.TryCreate(expected,poll,out target) && target==expected;
    }
    public Task<string> ExecuteAsync(string name,string argsJson) { return ExecuteAsync(name,argsJson,lifetime.Token); }
    async Task<string> ExecuteAsync(string name,string argsJson,CancellationToken userCancel) {
        string id="";Dictionary<string,object> job=null;bool owned=false;
        try {
            CheckSession();await single.WaitAsync(userCancel).ConfigureAwait(false);owned=true;CheckSession();
            var budget=System.Diagnostics.Stopwatch.StartNew();
            Dictionary<string,object> args;try{args=Obj(Json().DeserializeObject(argsJson));}catch{throw new ArgumentException("Invalid tool arguments");}if(args==null)throw new ArgumentException("Invalid tool arguments");
            Dictionary<string,object> cfg=config;
            if(name=="resume_image_task") {
                foreach(var key in args.Keys)if(key!="job_id")throw new ArgumentException("Unsupported tool argument");
                id=Str(args,"job_id");job=LoadJob(id);cfg=Obj(job["config"]);
                if(Str(job,"status")=="completed")return Serialize(job["result"]);
                if(Str(job,"task_id")=="" && !job.ContainsKey("provider_result"))return Serialize(Result("unknown",id,"No provider task ID was received. Do not resubmit automatically.",false));
                if(Str(job,"status")=="unsupported_task")return Serialize(Result("unknown",id,"已保留任务编号，但查询协议尚未支持。不会猜测查询地址或重新提交。",false));
            }else {
                bool edit=name=="edit_image";if(!edit && name!="generate_image")throw new ArgumentException("Unknown image tool");
                foreach(var key in args.Keys)if(key!="prompt" && !(edit && key=="reference_image_paths"))throw new ArgumentException("Unsupported tool argument");
                string prompt=Str(args,"prompt");if(String.IsNullOrWhiteSpace(prompt) || prompt.Length>16000)throw new ArgumentException("Image prompt required (maximum 16000 characters)");
                // Validate reference inputs before creating a provider task.
                using(var bodyCheck=Body(cfg,prompt,args,edit)){}
                id=Guid.NewGuid().ToString("N");ActiveJobId=id;
                job=Map("config",cfg,"status","submitting","task_id","","created_at",DateTime.UtcNow.ToString("o"));SaveJob(id,job);
                Stage="submitting";
                using(var deadline=CancellationTokenSource.CreateLinkedTokenSource(userCancel)) {
                    deadline.CancelAfter(TimeSpan.FromSeconds(Math.Max(60,Math.Min(1800,Num(cfg,"wait_seconds",600)))));
                    using(var client=Client(cfg))using(var request=Request(HttpMethod.Post,new Uri(Str(cfg,"base_url").TrimEnd('/')+(Str(cfg,"protocol")=="responses_image"?"/responses":edit?"/images/edits":"/images/generations")),Str(cfg,"key"))) {
                        request.Content=Body(cfg,prompt,args,edit);
                        using(var response=await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,deadline.Token).ConfigureAwait(false)) {
                            if(Str(cfg,"protocol")=="responses_image" && ((int)response.StatusCode==400 || (int)response.StatusCode==404 || (int)response.StatusCode==422))throw new InvalidDataException("此接口不支持该图片调用方式，或请求参数不被支持。请核对服务商文档；普通聊天仍可使用。");
                            var value=await ReadJson(response,deadline.Token).ConfigureAwait(false);
                            if(Str(cfg,"protocol")=="responses_image")value=ResponseImages(value);
                            if(HasImages(value)) {
                                // Retain completed provider output before downloading, so interrupted downloads can resume.
                                job["provider_result"]=value;job["status"]="downloading";SaveJob(id,job);
                                Stage="downloading";var result=await SaveResult(client,value,cfg,id,deadline.Token).ConfigureAwait(false);CompleteJob(id,job,result);return Serialize(result);
                            }
                            string taskId=Str(value,"id");bool known=KnownTask(value,cfg,taskId);
                            if(taskId!="") {job["task_id"]=taskId;job["status"]=known?Str(value,"status","queued"):"unsupported_task";SaveJob(id,job);}
                            if(!known)return Serialize(Result("unknown",id,taskId!=""?"已保留任务编号，但查询协议尚未支持。不会猜测地址或重复提交。":"未识别到图片或可查询任务，结果尚未确认。不会重复提交。",false));
                            if(Str(cfg,"protocol")=="images_sync")return Serialize(Result("pending",id,"服务商返回了异步任务，已保存。可使用续取工具查询，无需再次生成。",true));
                        }
                    }
                }
            }
            ActiveJobId=id;
            using(var deadline=CancellationTokenSource.CreateLinkedTokenSource(userCancel)) {
                // Submission, polling and downloading share one configured wait budget.
                deadline.CancelAfter(TimeSpan.FromMilliseconds(Math.Max(1,1000.0*Math.Max(60,Math.Min(1800,Num(cfg,"wait_seconds",600)))-budget.Elapsed.TotalMilliseconds)));
                using(var client=Client(cfg)) {
                    object cached;if(job.TryGetValue("provider_result",out cached)) {Stage="downloading";var saved=await SaveResult(client,Obj(cached),cfg,id,deadline.Token).ConfigureAwait(false);CompleteJob(id,job,saved);return Serialize(saved);}
                    int transient=0;
                    for(;;) {
                        CheckSession();deadline.Token.ThrowIfCancellationRequested();
                        Stage=Str(job,"status","queued");
                        var url=new Uri(Str(cfg,"base_url").TrimEnd('/')+"/images/tasks/"+Uri.EscapeDataString(Str(job,"task_id")));
                        using(var request=Request(HttpMethod.Get,url,Str(cfg,"key")))
                        using(var response=await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,deadline.Token).ConfigureAwait(false)) {
                            if((int)response.StatusCode==429 || (int)response.StatusCode>=500) {
                                int delay=Math.Min(30,3*(++transient));if(response.Headers.RetryAfter!=null && response.Headers.RetryAfter.Delta.HasValue)delay=Math.Min(60,(int)Math.Ceiling(response.Headers.RetryAfter.Delta.Value.TotalSeconds));
                                await Task.Delay(Math.Max(1,delay)*1000,deadline.Token).ConfigureAwait(false);continue;
                            }
                            transient=0;var value=await ReadJson(response,deadline.Token).ConfigureAwait(false);string state=Str(value,"status");
                            if(state=="completed") {
                                job["status"]="downloading";job["provider_result"]=value["result"];SaveJob(id,job);
                                Stage="downloading";var result=await SaveResult(client,Obj(value["result"]),cfg,id,deadline.Token).ConfigureAwait(false);CompleteJob(id,job,result);return Serialize(result);
                            }
                            if(state=="failed") { job["status"]="failed";SaveJob(id,job);return Serialize(Result("failed",id,"Provider reported image generation failure. No task was resubmitted.",false)); }
                            if(state!="queued" && state!="in_progress")throw new InvalidDataException("Unsupported image task status");
                            job["status"]=state;SaveJob(id,job);
                        }
                        await Task.Delay(3000,deadline.Token).ConfigureAwait(false);
                    }
                }
            }
        }catch(OperationCanceledException) {
            bool resume=job!=null && (job.ContainsKey("provider_result") || Str(job,"task_id")!="" && Str(job,"status")!="unsupported_task");
            return Serialize(Result(userCancel.IsCancellationRequested?"cancelled":"pending",id,"Stopped local waiting. The provider may still be generating; do not resubmit automatically.",resume));
        }catch(Exception ex) {
            bool resume=job!=null && (job.ContainsKey("provider_result") || Str(job,"task_id")!="" && Str(job,"status")!="unsupported_task");
            string message=ex is HttpRequestException && ex.Message.StartsWith("Image ") ? ex.Message : ex is ArgumentException || ex is InvalidDataException || ex is InvalidOperationException ? ex.Message : "Image operation could not finish. Check the service configuration and network.";
            return Serialize(Result("failed",id,message,resume));
        }finally { Stage="finished";if(owned)single.Release(); }
    }
    void CompleteJob(string id,Dictionary<string,object> job,Dictionary<string,object> result) {
        job["status"]="completed";var saved=new Dictionary<string,object>(result);saved.Remove("previews");job["result"]=saved;job.Remove("provider_result");
        // Completed jobs no longer need a retained provider credential.
        job["config"]=Map("service_id",Str(Obj(job["config"]),"service_id"));SaveJob(id,job);
    }
    void Write(object value) { lock(outputLock) { Console.Out.WriteLine(Serialize(value));Console.Out.Flush(); } }
    static object Schema(bool edit,bool resume) {
        var props=new Dictionary<string,object>();
        if(resume)props["job_id"]=Map("type","string","description","Local job ID returned by this image tool; never a provider URL.");
        else { props["prompt"]=Map("type","string","description","User-requested image generation or modification instructions.");if(edit)props["reference_image_paths"]=Map("type","array","minItems",1,"maxItems",16,"items",Map("type","string"),"description","Absolute local paths to reference images explicitly supplied by the user. Inspect the images before editing."); }
        return Map("type","object","properties",props,"required",resume?new[]{"job_id"}:edit?new[]{"prompt","reference_image_paths"}:new[]{"prompt"},"additionalProperties",false);
    }
    object ToolList() { return Map("tools",new object[]{
        Map("name","generate_image","description","Generate one image using the configured third-party image service, only when the user explicitly requests an image. This does not switch the conversation model. May incur provider charges.","inputSchema",Schema(false,false)),
        Map("name","edit_image","description","Modify user-specified reference images using the configured third-party image service. Return a new file; do not overwrite the originals. May incur provider charges.","inputSchema",Schema(true,false)),
        Map("name","resume_image_task","description","Continue waiting for or download an existing asynchronous image job without submitting or billing a new generation task.","inputSchema",Schema(false,true)) }); }
    public void RunStdio() {
        Console.InputEncoding=new UTF8Encoding(false);Console.OutputEncoding=new UTF8Encoding(false);
        bool initialized=false;string line;
        while((line=Console.In.ReadLine())!=null) {
            if(line.Length>1024*1024) { Write(Map("jsonrpc","2.0","id",null,"error",Map("code",-32700,"message","Message too large")));continue; }
            Dictionary<string,object> message;
            try { message=Obj(Json().DeserializeObject(line));if(message==null || Str(message,"jsonrpc")!="2.0")throw new Exception(); }
            catch { Write(Map("jsonrpc","2.0","id",null,"error",Map("code",-32700,"message","Invalid JSON-RPC")));continue; }
            object id;bool hasId=message.TryGetValue("id",out id);string method=Str(message,"method");object raw;var args=message.TryGetValue("params",out raw)?Obj(raw):null;
            if(method=="notifications/cancelled") { CancellationTokenSource c;string requestId=Str(args,"requestId");if(calls.TryGetValue(requestId,out c))c.Cancel();continue; }
            if(!hasId) { if(method=="notifications/initialized")initialized=true;continue; }
            if(method=="initialize") {
                string requested=Str(args,"protocolVersion");string version=Array.IndexOf(new[]{"2025-11-25","2025-06-18","2025-03-26","2024-11-05"},requested)>=0?requested:"2025-06-18";
                Write(Map("jsonrpc","2.0","id",id,"result",Map("protocolVersion",version,"capabilities",Map("tools",Map("listChanged",false)),"serverInfo",Map("name","codex-launcher-images","version","0.3.0"),"instructions","In this API mode the user enabled an image service or the dialogue API image-generation tool. Use these tools when the user explicitly requests generation or editing. Keep the conversation model unchanged. Do not call image tools for unrelated coding tasks. For pending jobs resume the returned local job ID instead of resubmitting. Render saved image paths inline; copy final project assets into the workspace. Never request or expose API keys.")));continue;
            }
            if(method=="ping") { Write(Map("jsonrpc","2.0","id",id,"result",Map()));continue; }
            if(!initialized) { Write(Map("jsonrpc","2.0","id",id,"error",Map("code",-32000,"message","Initialize the server first")));continue; }
            if(method=="tools/list") { Write(Map("jsonrpc","2.0","id",id,"result",ToolList()));continue; }
            if(method!="tools/call") { Write(Map("jsonrpc","2.0","id",id,"error",Map("code",-32601,"message","Method not found")));continue; }
            var callId=id;string name=Str(args,"name");object toolArgs=args!=null && args.TryGetValue("arguments",out raw)?raw:Map();
            var cancel=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);string idKey=Convert.ToString(id);
            if(!calls.TryAdd(idKey,cancel)) { cancel.Dispose();Write(Map("jsonrpc","2.0","id",id,"error",Map("code",-32600,"message","Duplicate active request ID")));continue; }
            Task.Run(async delegate {
                try {
                    var value=Obj(Json().DeserializeObject(await ExecuteAsync(name,Serialize(toolArgs),cancel.Token).ConfigureAwait(false)));
                    var content=new List<object>();object images;value.TryGetValue("previews",out images);
                    // Image bytes belong in image blocks, never duplicated inside text.
                    value.Remove("previews");content.Add(Map("type","text","text",Serialize(value)));
                    if(images!=null)foreach(var preview in (IEnumerable)images)content.Add(preview);
                    Write(Map("jsonrpc","2.0","id",callId,"result",Map("content",content,"structuredContent",value,"isError",Str(value,"status")=="failed" || Str(value,"status")=="unknown")));
                }finally { CancellationTokenSource removed;calls.TryRemove(idKey,out removed);cancel.Dispose(); }
            });
        }
        lifetime.Cancel();
        for(int i=0;i<100 && !calls.IsEmpty;i++)Thread.Sleep(20);
    }
    public void Dispose() { lifetime.Cancel(); }
}

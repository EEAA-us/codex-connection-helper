using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

// Supported app-server RPC only. Never loads chat bodies, prints responses or refreshes tokens.
public sealed class CodexNativeProbe : IDisposable {
    static readonly object inputEncodingLock=new object();
    static Process StartUtf8Process(ProcessStartInfo start) {
        // .NET Framework has no ProcessStartInfo.StandardInputEncoding.
        // Process.Start creates an AutoFlush writer using Console.InputEncoding;
        // with a UTF-8 BOM console it emits a preamble before our writer exists.
        lock(inputEncodingLock) {
            var previous=Console.InputEncoding;
            try { Console.InputEncoding=new UTF8Encoding(false);return Process.Start(start); }
            finally { Console.InputEncoding=previous; }
        }
    }
    Process process;
    StreamWriter input;
    readonly CancellationTokenSource cancel=new CancellationTokenSource();
    int sequence;
    public string Stage {get;private set;}
    static JavaScriptSerializer Json(){return new JavaScriptSerializer{MaxJsonLength=16*1024*1024,RecursionLimit=60};}
    public void Cancel(){cancel.Cancel();var target=process;try{if(target!=null && !target.HasExited)target.Kill();}catch(InvalidOperationException){}catch(System.ComponentModel.Win32Exception){}}
    public Task<string> RunAsync(string engine,string home,string ui,string cwd,string repairJson) {
        return RunCoreAsync(engine,home,ui,cwd,repairJson,true);
    }
    public Task<string> RunPluginsAsync(string engine,string home,string ui,string cwd,string repairJson) {
        return RunCoreAsync(engine,home,ui,cwd,repairJson,false);
    }
    async Task<string> RunCoreAsync(string engine,string home,string ui,string cwd,string repairJson,bool connections) {
        var psi=new ProcessStartInfo(engine,"app-server --stdio"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8,WorkingDirectory=cwd};
        foreach(var name in new[]{"OPENAI_API_KEY","CODEX_API_KEY","OPENAI_BASE_URL","CODEX_HOME","CODEX_ELECTRON_USER_DATA_PATH"})psi.EnvironmentVariables.Remove(name);
        psi.EnvironmentVariables["CODEX_HOME"]=home;psi.EnvironmentVariables["CODEX_ELECTRON_USER_DATA_PATH"]=ui;
        process=StartUtf8Process(psi);
        // Windows PowerShell 5.1's default pipe writer follows the system code page.
        // Rust app-server expects UTF-8, including Chinese cwd and marketplace paths.
        input=new StreamWriter(process.StandardInput.BaseStream,new UTF8Encoding(false)){AutoFlush=true};
        process.ErrorDataReceived+=(s,e)=>{};process.BeginErrorReadLine();
        try {
            await Rpc("initialize",new{clientInfo=new{name="codex_launcher_compatibility",version="0.3.0"},capabilities=new{experimentalApi=true}}).ConfigureAwait(false);
            await input.WriteLineAsync("{\"method\":\"initialized\"}").ConfigureAwait(false);await input.FlushAsync().ConfigureAwait(false);
            var result=new Dictionary<string,object>();
            var accountResponse=await Rpc("account/read",new{refreshToken=false}).ConfigureAwait(false) as Dictionary<string,object>;
            object accountValue;
            var account=accountResponse!=null && accountResponse.TryGetValue("account",out accountValue) ? accountValue as Dictionary<string,object> : null;
            object accountType;
            result["account"]=new{type=account!=null && account.TryGetValue("type",out accountType) ? Convert.ToString(accountType) : null};
            if(!String.IsNullOrEmpty(repairJson)) {
                var repair=Json().DeserializeObject(repairJson) as Dictionary<string,object>;
                object expected;
                var nativeType=account!=null && account.TryGetValue("type",out accountType) ? Convert.ToString(accountType) : "";
                var nativeMode=nativeType=="apiKey" ? "api" : nativeType=="chatgpt" || nativeType=="chatgptAuthTokens" ? "official" : "unknown";
                if(repair==null || !repair.TryGetValue("launcherExpectedMode",out expected) || nativeMode=="unknown" || Convert.ToString(expected)!=nativeMode)
                    throw new InvalidOperationException("安装前的原生登录与检查结果不同；请重新检查后再操作。未提交插件安装。");
                repair.Remove("launcherExpectedMode");
                result["repair"]=await Rpc("plugin/install",repair).ConfigureAwait(false);
            }
            result["plugins"]=await Rpc("plugin/installed",new{cwds=new[]{cwd},installSuggestionPluginNames=new[]{"figma","design-partner"}}).ConfigureAwait(false);
            result["skills"]=await Rpc("skills/list",new{cwds=new[]{cwd},forceReload=true}).ConfigureAwait(false);
            if(connections) {
                // An optional connection failure must not discard the inventory already read.
                try {
                    result["mcp"]=await Rpc("mcpServerStatus/list",new{detail="toolsAndAuthOnly",limit=100}).ConfigureAwait(false);
                    result["apps"]=await Rpc("app/installed",new{forceRefresh=false}).ConfigureAwait(false);
                } catch(TimeoutException) { result["connection_issue"]="timeout"; }
                  catch(IOException) { result["connection_issue"]="engine_exit"; }
            }
            return Json().Serialize(result);
        }finally{Dispose();}
    }
    async Task<object> Rpc(string method,object args) {
        switch(method){case "initialize":Stage="初始化";break;case "account/read":Stage="登录识别";break;case "plugin/install":Stage="插件安装";break;case "plugin/installed":Stage="插件清单";break;case "skills/list":Stage="技能发现";break;case "mcpServerStatus/list":Stage="MCP 连接";break;case "app/installed":Stage="App 连接";break;}
        int id=++sequence;
        await input.WriteLineAsync(Json().Serialize(new{method=method,@params=args,id=id})).ConfigureAwait(false);await input.FlushAsync().ConfigureAwait(false);
        var deadline=DateTime.UtcNow.AddSeconds(20);
        while(DateTime.UtcNow<deadline) {
            cancel.Token.ThrowIfCancellationRequested();var reading=process.StandardOutput.ReadLineAsync();
            if(await Task.WhenAny(reading,Task.Delay(Math.Max(1,(int)(deadline-DateTime.UtcNow).TotalMilliseconds),cancel.Token)).ConfigureAwait(false)!=reading)throw new TimeoutException("Native compatibility query timed out");
            var line=await reading.ConfigureAwait(false);if(line==null)throw new IOException("Native engine exited");if(line.Length>16*1024*1024)throw new IOException("Native response too large");
            var msg=Json().DeserializeObject(line) as Dictionary<string,object>;object found;
            if(msg==null || !msg.TryGetValue("id",out found) || Convert.ToString(found)!=id.ToString())continue;
            if(msg.ContainsKey("error")) {
                var error=msg["error"] as Dictionary<string,object>;object messageValue;
                var message=error!=null && error.TryGetValue("message",out messageValue) ? Convert.ToString(messageValue) : "";
                if(method=="plugin/install" && (message.Contains("api key auth is not supported") || message.Contains("chatgpt authentication required for remote plugin catalog")))
                    return new Dictionary<string,object>{{"query_status","blocked"},{"failure_kind","native_api_catalog_auth"},{"reason","当前原生引擎不支持 API Key 登录安装官方远程市场插件。市场可搜索不代表可以安装；请在官方模式管理账号插件，本地 MCP 连接需单独核对。"}};
                return new Dictionary<string,object>{{"query_status","unobserved"},{"reason","原生查询未返回结果；可能是版本、登录方式或连接限制。"}};
            }
            return msg.ContainsKey("result")?msg["result"]:null;
        }throw new TimeoutException("Native compatibility query timed out");
    }
    public void Dispose(){var writer=Interlocked.Exchange(ref input,null);if(writer!=null){try{writer.Dispose();}catch{}}var target=Interlocked.Exchange(ref process,null);if(target!=null){try{target.StandardInput.Close();}catch{}try{if(!target.WaitForExit(1000))target.Kill();}catch{}target.Dispose();}}
}

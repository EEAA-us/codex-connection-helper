using System;
using System.IO;
using System.Diagnostics;
using System.Reflection;
using System.Windows.Forms;
[assembly: AssemblyTitle("Codex Connection Helper")]
[assembly: AssemblyVersion("0.3.18.0")]
internal static class DesktopEntry {
    [STAThread] static int Main(string[] args) {
        try {
            string root=Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
#if SETUP
            string script="Install.ps1";
#else
            string script="Launcher.ps1";
#endif
            string file=Path.Combine(root,script);
            if(!File.Exists(file))throw new FileNotFoundException("请先完整解压 ZIP，再打开助手。程序文件缺失："+script);
            string powershell=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");
            var start=new ProcessStartInfo(powershell,"-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \""+file+"\"") {
                UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden,WorkingDirectory=root
            };
            if(args.Length==1 && args[0]=="--check")start.Arguments+=" -ValidateOnly";
            else if(args.Length!=0)throw new ArgumentException("请直接双击图标打开助手。");
            using(var process=Process.Start(start)){process.WaitForExit();return process.ExitCode;}
        }catch(Exception e){MessageBox.Show(e.Message,"Codex 连接助手",MessageBoxButtons.OK,MessageBoxIcon.Error);return 1;}
    }
}

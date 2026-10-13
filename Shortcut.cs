using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class CodexShortcut {
    [ComImport,Guid("00021401-0000-0000-C000-000000000046")] class ShellLink {}
    [ComImport,Guid("000214F9-0000-0000-C000-000000000046"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellLinkW {
        void GetPath([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder file,int count,IntPtr data,uint flags);
        void GetIDList(out IntPtr id);
        void SetIDList(IntPtr id);
        void GetDescription([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder description,int count);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string description);
        void GetWorkingDirectory([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder directory,int count);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
        void GetArguments([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder arguments,int count);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int command);
        void SetShowCmd(int command);
        void GetIconLocation([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder path,int count,out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path,int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path,uint reserved);
        void Resolve(IntPtr window,uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }
    public static void Create(string linkFile,string executable,string workingDirectory,string icon) {
        var link=(IShellLinkW)new ShellLink();
        try {
            link.SetPath(executable);link.SetArguments("");link.SetWorkingDirectory(workingDirectory);
            link.SetDescription("官方账号与第三方 API 切换，共用原来的本机记录");link.SetIconLocation(icon,0);link.SetShowCmd(1);
            ((IPersistFile)link).Save(linkFile,true);
        }finally{Marshal.FinalReleaseComObject(link);}
    }
    public static string ReadTarget(string linkFile) {return ReadString(linkFile,0);}
    public static string ReadWorkingDirectory(string linkFile) {return ReadString(linkFile,1);}
    public static string ReadArguments(string linkFile) {return ReadString(linkFile,2);}
    static string ReadString(string linkFile,int field) {
        var link=(IShellLinkW)new ShellLink();
        try {
            ((IPersistFile)link).Load(linkFile,0);var path=new StringBuilder(32768);
            if(field==0)link.GetPath(path,path.Capacity,IntPtr.Zero,0);
            else if(field==1)link.GetWorkingDirectory(path,path.Capacity);
            else link.GetArguments(path,path.Capacity);
            return path.ToString();
        }
        finally{Marshal.FinalReleaseComObject(link);}
    }
}

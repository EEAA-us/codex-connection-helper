using System;
using System.Runtime.InteropServices;

// Uses the installed package's launch contract, icon and application identity.
// No application binaries, shortcuts, notification settings or registry are patched.
public static class CodexDesktopActivation {
    [ComImport, Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IApplicationActivationManager {
        [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
        [PreserveSig] int ActivateForFile([MarshalAs(UnmanagedType.LPWStr)] string appId,
            [MarshalAs(UnmanagedType.Interface)] object items, [MarshalAs(UnmanagedType.LPWStr)] string verb, out uint processId);
        [PreserveSig] int ActivateForProtocol([MarshalAs(UnmanagedType.LPWStr)] string appId,
            [MarshalAs(UnmanagedType.Interface)] object items, out uint processId);
    }
    public static int Activate(string appId) {
        if(String.IsNullOrWhiteSpace(appId)) throw new ArgumentException("Missing registered application identity");
        var type=Type.GetTypeFromCLSID(new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C"));
        var manager=(IApplicationActivationManager)Activator.CreateInstance(type);
        try {
            uint pid;
            int hr=manager.ActivateApplication(appId, null, 2, out pid); // AO_NOERRORUI
            if(hr < 0) Marshal.ThrowExceptionForHR(hr);
            if(pid == 0 || pid > Int32.MaxValue) throw new InvalidOperationException("No activated application process");
            return (int)pid;
        } finally { Marshal.FinalReleaseComObject(manager); }
    }
}

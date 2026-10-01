# Inspect users of one retained release file. Never stop or restart a process.
param(
  [string]$FilePath,
  [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class ReleaseFileInspector {
  [StructLayout(LayoutKind.Sequential)]
  public struct ProcessIdentity {
    public uint ProcessId;
    public System.Runtime.InteropServices.ComTypes.FILETIME Started;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct ProcessInfo {
    public ProcessIdentity Identity;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Application;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string Service;
    public uint Type;
    public uint Status;
    public uint SessionId;
    [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
  }
  [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
  static extern int RmStartSession(out uint session, uint flags, StringBuilder key);
  [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
  static extern int RmRegisterResources(uint session, uint files, string[] paths,
    uint applications, IntPtr processes, uint services, IntPtr serviceNames);
  [DllImport("rstrtmgr.dll")]
  static extern int RmGetList(uint session, out uint needed, ref uint count,
    [In, Out] ProcessInfo[] processes, out uint reasons);
  [DllImport("rstrtmgr.dll")]
  static extern int RmEndSession(uint session);
  public static ProcessInfo[] Inspect(string path) {
    uint session;
    int rc = RmStartSession(out session, 0, new StringBuilder(33));
    if (rc != 0) throw new Win32Exception(rc, "RmStartSession");
    try {
      rc = RmRegisterResources(session, 1, new string[] {path}, 0, IntPtr.Zero, 0, IntPtr.Zero);
      if (rc != 0) throw new Win32Exception(rc, "RmRegisterResources");
      uint needed = 0, count = 0, reasons;
      ProcessInfo[] rows = null;
      for (int attempt = 0; attempt < 4; attempt++) {
        rc = RmGetList(session, out needed, ref count, rows, out reasons);
        if (rc == 0) {
          if (rows == null) return new ProcessInfo[0];
          Array.Resize(ref rows, (int)count);
          return rows;
        }
        if (rc != 234) throw new Win32Exception(rc, "RmGetList");
        count = needed;
        rows = new ProcessInfo[count];
      }
      throw new InvalidOperationException("File-user census kept changing");
    } finally { RmEndSession(session); }
  }
}
'@
if ($ValidateOnly) { Write-Host 'Restart Manager bindings compile'; return }
if (-not $IsWindows) { throw 'This diagnostic requires Windows' }
if (-not $FilePath) { throw 'FilePath is required' }
Write-Host "runner=$env:RUNNER_NAME host=$env:COMPUTERNAME"
if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
  Write-Host "The previously retained file is absent: $FilePath"
  return
}
Get-Item -LiteralPath $FilePath | Select-Object FullName, Length, Attributes, LastWriteTimeUtc | Format-List
Get-Acl -LiteralPath $FilePath | Select-Object Owner, AccessToString | Format-List
$rows = [ReleaseFileInspector]::Inspect($FilePath)
$rows | ConvertTo-Json -Depth 4
foreach ($row in $rows) {
  Get-CimInstance Win32_Process -Filter "ProcessId=$($row.Identity.ProcessId)" |
    Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CreationDate |
    ConvertTo-Json
}
# Also retain likely source-build processes if Restart Manager cannot identify
# the image section. No command lines or environment values are collected.
Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(repro.*|runquota.*)\.exe$' } |
  Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CreationDate |
  ConvertTo-Json

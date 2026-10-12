Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:HardwareId = 'Root\WinSideUSBVirtualDisplay'
$script:LogPath = ''
$script:SignedVendorHashes = @{
    'MttVDD.inf' = '550D211FE481E74DFE3F9D724ED78BE48B3A9113405965D683D9373E8D672F5D'
    'MttVDD.dll' = 'C9CA837F57A98FBD43BC416A7F535A95843626E7759EAF85CF0CD7CE334DBB05'
    'MttVDD.cat' = '08A0093FC9B2E32B287A6F8A77CA4DE0A31830D29FC33D2B13A918DC859468F6'
}

# All native entry points live here so the transaction can be exercised with
# mocks without adding certificates, staging packages, or touching devices.
function Initialize-SetupNative {
    if (([System.Management.Automation.PSTypeName]'WinSideUSB.SetupNative').Type) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;

namespace WinSideUSB {
    public sealed class DeviceState {
        public string InstanceId;
        public string[] HardwareIds;
        public string PublishedInf;
        public uint ProblemCode;
        public uint Status;
    }
    public static class SetupNative {
        private static readonly Guid DisplayClass = new Guid("4d36e968-e325-11ce-bfc1-08002be10318");
        private const string HardwareId = "Root\\WinSideUSBVirtualDisplay";
        private static readonly IntPtr InvalidHandle = new IntPtr(-1);
        [StructLayout(LayoutKind.Sequential)] private struct DeviceInfo {
            public int Size; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved;
        }
        [StructLayout(LayoutKind.Sequential)] private struct RemoveParams {
            public int HeaderSize; public int InstallFunction; public int Scope; public int Profile;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ChangeParams {
            public int HeaderSize; public int InstallFunction; public int StateChange; public int Scope; public int Profile;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct InstallParams {
            public int Size; public uint Flags; public uint FlagsEx; public IntPtr Parent;
            public IntPtr Callback; public IntPtr Context; public IntPtr FileQueue;
            public UIntPtr ClassReserved; public uint Reserved;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string DriverPath;
        }
        [StructLayout(LayoutKind.Sequential)] private struct CodeIntegrityInfo {
            public uint Length; public uint Options;
        }
        [DllImport("setupapi.dll", SetLastError = true)] private static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid classGuid, IntPtr parent);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr SetupDiGetClassDevs(ref Guid classGuid, string enumerator, IntPtr parent, int flags);
        [DllImport("setupapi.dll", SetLastError = true)] private static extern bool SetupDiEnumDeviceInfo(IntPtr set, uint index, ref DeviceInfo data);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetupDiCreateDeviceInfo(IntPtr set, string name, ref Guid classGuid, string description, IntPtr parent, int flags, ref DeviceInfo data);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetupDiGetDeviceInstanceId(IntPtr set, ref DeviceInfo data, StringBuilder id, int length, out int required);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetupDiOpenDeviceInfo(IntPtr set, string id, IntPtr parent, int flags, ref DeviceInfo data);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetupDiGetDeviceRegistryProperty(IntPtr set, ref DeviceInfo data, int property, out uint type, byte[] buffer, uint length, out uint required);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetupDiSetDeviceRegistryProperty(IntPtr set, ref DeviceInfo data, int property, byte[] buffer, int length);
        [DllImport("setupapi.dll", SetLastError = true)] private static extern bool SetupDiSetClassInstallParams(IntPtr set, ref DeviceInfo data, ref RemoveParams parameters, int size);
        [DllImport("setupapi.dll", SetLastError = true)] private static extern bool SetupDiSetClassInstallParams(IntPtr set, ref DeviceInfo data, ref ChangeParams parameters, int size);
        [DllImport("setupapi.dll", SetLastError = true)] private static extern bool SetupDiCallClassInstaller(int function, IntPtr set, ref DeviceInfo data);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetupDiGetDeviceInstallParams(IntPtr set, ref DeviceInfo data, ref InstallParams parameters);
        [DllImport("setupapi.dll", SetLastError = true)] private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
        [DllImport("newdev.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr parent, string hardwareId, string inf, int flags, out bool reboot);
        [DllImport("cfgmgr32.dll")] private static extern uint CM_Get_DevNode_Status(out uint status, out uint problem, uint devInst, uint flags);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetupGetInfDriverStoreLocation(string inf, IntPtr platform, string locale, StringBuilder buffer, int length, out int required);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetupGetInfPublishedName(string storeInf, StringBuilder buffer, int length, out int required);
        [DllImport("ntdll.dll")] private static extern int NtQuerySystemInformation(int informationClass, ref CodeIntegrityInfo info, int length, out int returned);
        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CryptCATOpen(string file, uint flags, IntPtr provider, uint version, uint encoding);
        [DllImport("wintrust.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CryptCATGetMemberInfo(IntPtr catalog, string referenceTag);
        [DllImport("wintrust.dll")] private static extern bool CryptCATClose(IntPtr catalog);
        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CryptCATAdminAcquireContext2(out IntPtr admin, IntPtr subsystem, string algorithm, IntPtr policy, uint flags);
        [DllImport("wintrust.dll", SetLastError = true)] private static extern bool CryptCATAdminCalcHashFromFileHandle2(IntPtr admin, IntPtr file, ref uint length, byte[] hash, uint flags);
        [DllImport("wintrust.dll")] private static extern bool CryptCATAdminReleaseContext(IntPtr admin, uint flags);
        private static void Ensure(bool result, string operation) {
            if (!result) throw new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed");
        }
        private static DeviceInfo NewInfo() {
            DeviceInfo data = new DeviceInfo(); data.Size = Marshal.SizeOf(typeof(DeviceInfo)); return data;
        }
        private static string[] ReadProperty(IntPtr set, ref DeviceInfo data, int property) {
            uint type, required; byte[] buffer = new byte[8192];
            if (!SetupDiGetDeviceRegistryProperty(set, ref data, property, out type, buffer, (uint)buffer.Length, out required)) {
                int error = Marshal.GetLastWin32Error();
                if (error == 13 || error == 1168) return new string[0];
                throw new Win32Exception(error, "Reading device property failed");
            }
            return Encoding.Unicode.GetString(buffer, 0, (int)required).Split(new char[] {'\0'}, StringSplitOptions.RemoveEmptyEntries);
        }
        private static string ReadId(IntPtr set, ref DeviceInfo data) {
            StringBuilder id = new StringBuilder(512); int required;
            Ensure(SetupDiGetDeviceInstanceId(set, ref data, id, id.Capacity, out required), "SetupDiGetDeviceInstanceId");
            return id.ToString();
        }
        private static bool HasHardware(string[] ids, string hardwareId) {
            foreach (string id in ids) if (String.Equals(id, hardwareId, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }
        public static bool TestSigningEnabled() {
            CodeIntegrityInfo info = new CodeIntegrityInfo(); info.Length = (uint)Marshal.SizeOf(typeof(CodeIntegrityInfo)); int returned;
            int status = NtQuerySystemInformation(103, ref info, (int)info.Length, out returned);
            if (status != 0) throw new InvalidOperationException("Unable to read active Windows code integrity policy: 0x" + status.ToString("X8"));
            return (info.Options & 2) != 0;
        }
        public static void VerifyCatalogMembers(string catalogPath, string[] members) {
            // Verifies the PKCS#7 signature independently of trust. Trust is
            // checked separately so a developer certificate need not be imported during Check.
            IntPtr catalog = CryptCATOpen(catalogPath, 0x10000004, IntPtr.Zero, 0, 0);
            if (catalog == IntPtr.Zero || catalog == InvalidHandle) throw new Win32Exception(Marshal.GetLastWin32Error(), "Catalog signature could not be verified");
            try {
                foreach (string file in members) {
                    bool found = false;
                    foreach (string algorithm in new string[] { "SHA256", "SHA1" }) {
                        IntPtr admin;
                        Ensure(CryptCATAdminAcquireContext2(out admin, IntPtr.Zero, algorithm, IntPtr.Zero, 0), "CryptCATAdminAcquireContext2");
                        try {
                            using (FileStream stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                                uint length = 0;
                                Ensure(CryptCATAdminCalcHashFromFileHandle2(admin, stream.SafeFileHandle.DangerousGetHandle(), ref length, null, 0), "Catalog member hash size");
                                byte[] hash = new byte[length];
                                Ensure(CryptCATAdminCalcHashFromFileHandle2(admin, stream.SafeFileHandle.DangerousGetHandle(), ref length, hash, 0), "Catalog member hash");
                                string tag = BitConverter.ToString(hash).Replace("-", "");
                                if (CryptCATGetMemberInfo(catalog, tag) != IntPtr.Zero || CryptCATGetMemberInfo(catalog, tag.ToLowerInvariant()) != IntPtr.Zero) found = true;
                            }
                        } finally { CryptCATAdminReleaseContext(admin, 0); }
                        if (found) break;
                    }
                    if (!found) throw new InvalidOperationException("The signed driver catalog does not contain the current contents of " + Path.GetFileName(file) + ". Rebuild and sign the complete package.");
                }
            } finally { CryptCATClose(catalog); }
        }
        public static DeviceState[] GetDevices() { return GetDevices(HardwareId); }
        public static DeviceState[] GetDevices(string hardwareId) {
            Guid classGuid = DisplayClass;
            IntPtr set = SetupDiGetClassDevs(ref classGuid, null, IntPtr.Zero, 0);
            if (set == InvalidHandle) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiGetClassDevs failed");
            List<DeviceState> devices = new List<DeviceState>();
            try {
                for (uint index = 0; ; index++) {
                    DeviceInfo data = NewInfo();
                    if (!SetupDiEnumDeviceInfo(set, index, ref data)) {
                        int error = Marshal.GetLastWin32Error(); if (error == 259) break;
                        throw new Win32Exception(error, "SetupDiEnumDeviceInfo failed");
                    }
                    string[] ids = ReadProperty(set, ref data, 1);
                    if (!HasHardware(ids, hardwareId)) continue;
                    DeviceState device = new DeviceState(); device.InstanceId = ReadId(set, ref data); device.HardwareIds = ids;
                    string[] keys = ReadProperty(set, ref data, 9);
                    if (keys.Length > 0) {
                        using (RegistryKey key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Class\" + keys[0])) {
                            if (key != null) device.PublishedInf = Convert.ToString(key.GetValue("InfPath", ""));
                        }
                    }
                    uint result = CM_Get_DevNode_Status(out device.Status, out device.ProblemCode, data.DevInst, 0);
                    if (result != 0) { device.ProblemCode = UInt32.MaxValue; device.Status = 0; }
                    devices.Add(device);
                }
            } finally { SetupDiDestroyDeviceInfoList(set); }
            return devices.ToArray();
        }
        public static string CreateDevice() { return CreateDevice(HardwareId, false); }
        public static string CreateDevice(string hardwareId, bool disabled) {
            Guid classGuid = DisplayClass; IntPtr set = SetupDiCreateDeviceInfoList(ref classGuid, IntPtr.Zero);
            if (set == InvalidHandle) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfoList failed");
            try {
                DeviceInfo data = NewInfo();
                string deviceName = hardwareId.Substring(hardwareId.LastIndexOf('\\') + 1);
                Ensure(SetupDiCreateDeviceInfo(set, deviceName, ref classGuid, "WinSideUSB Virtual Display", IntPtr.Zero, 1, ref data), "SetupDiCreateDeviceInfo");
                byte[] hardware = Encoding.Unicode.GetBytes(hardwareId + "\0\0");
                Ensure(SetupDiSetDeviceRegistryProperty(set, ref data, 1, hardware, hardware.Length), "Setting hardware ID");
                if (disabled) {
                    byte[] flags = BitConverter.GetBytes(1); // CONFIGFLAG_DISABLED, before registration/binding.
                    Ensure(SetupDiSetDeviceRegistryProperty(set, ref data, 12, flags, flags.Length), "Creating disabled root device");
                }
                string instanceId = ReadId(set, ref data);
                Ensure(SetupDiCallClassInstaller(0x19, set, ref data), "Registering root device");
                return instanceId;
            } finally { SetupDiDestroyDeviceInfoList(set); }
        }
        public static bool BindDriver(string inf) { return BindDriver(inf, HardwareId); }
        public static bool BindDriver(string inf, string hardwareId) {
            bool reboot; Ensure(UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, hardwareId, inf, 5, out reboot), "Binding virtual display driver"); return reboot;
        }
        public static bool SetDeviceEnabled(string instanceId, string hardwareId, bool enabled) {
            Guid classGuid = DisplayClass; IntPtr set = SetupDiCreateDeviceInfoList(ref classGuid, IntPtr.Zero);
            if (set == InvalidHandle) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfoList failed");
            try {
                DeviceInfo data = NewInfo();
                Ensure(SetupDiOpenDeviceInfo(set, instanceId, IntPtr.Zero, 0, ref data), "Opening owned display");
                if (!HasHardware(ReadProperty(set, ref data, 1), hardwareId)) throw new InvalidOperationException("Managed device hardware ID changed.");
                ChangeParams change = new ChangeParams(); change.HeaderSize = 8; change.InstallFunction = 0x12; change.StateChange = enabled ? 1 : 2;
                foreach (int scope in new int[] { 1, 2 }) {
                    change.Scope = scope;
                    Ensure(SetupDiSetClassInstallParams(set, ref data, ref change, Marshal.SizeOf(typeof(ChangeParams))), "Setting device state parameters");
                    Ensure(SetupDiCallClassInstaller(0x12, set, ref data), "Changing managed device state");
                }
                InstallParams parameters = new InstallParams(); parameters.Size = Marshal.SizeOf(typeof(InstallParams));
                Ensure(SetupDiGetDeviceInstallParams(set, ref data, ref parameters), "Reading display restart flags");
                return (parameters.Flags & 0x180) != 0;
            } finally { SetupDiDestroyDeviceInfoList(set); }
        }
        public static bool RemoveDevice(string instanceId) { return RemoveDevice(instanceId, HardwareId); }
        public static bool RemoveDevice(string instanceId, string hardwareId) {
            Guid classGuid = DisplayClass; IntPtr set = SetupDiCreateDeviceInfoList(ref classGuid, IntPtr.Zero);
            if (set == InvalidHandle) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfoList failed");
            try {
                DeviceInfo data = NewInfo();
                if (!SetupDiOpenDeviceInfo(set, instanceId, IntPtr.Zero, 0, ref data)) {
                    int error = Marshal.GetLastWin32Error();
                    if (error == unchecked((int)0xe000020b) || error == 1168) return false; // Already removed.
                    throw new Win32Exception(error, "Opening owned device failed");
                }
                if (!HasHardware(ReadProperty(set, ref data, 1), hardwareId)) throw new InvalidOperationException("The saved device instance now belongs to another hardware ID; it was preserved.");
                RemoveParams removal = new RemoveParams(); removal.HeaderSize = 8; removal.InstallFunction = 5; removal.Scope = 1;
                Ensure(SetupDiSetClassInstallParams(set, ref data, ref removal, Marshal.SizeOf(typeof(RemoveParams))), "SetupDiSetClassInstallParams");
                Ensure(SetupDiCallClassInstaller(5, set, ref data), "Removing owned device");
                InstallParams parameters = new InstallParams(); parameters.Size = Marshal.SizeOf(typeof(InstallParams));
                Ensure(SetupDiGetDeviceInstallParams(set, ref data, ref parameters), "Reading removal restart flags");
                return (parameters.Flags & 0x180) != 0;
            } finally { SetupDiDestroyDeviceInfoList(set); }
        }
        private static bool SameFileContents(string source, string candidate) {
            if (!File.Exists(source) || !File.Exists(candidate)) return false;
            if (new FileInfo(source).Length != new FileInfo(candidate).Length) return false;
            using (SHA256 hash = SHA256.Create()) {
                byte[] first, second;
                using (FileStream stream = File.OpenRead(source)) first = hash.ComputeHash(stream);
                using (FileStream stream = File.OpenRead(candidate)) second = hash.ComputeHash(stream);
                for (int index = 0; index < first.Length; ++index) if (first[index] != second[index]) return false;
                return true;
            }
        }
        private static string FindStoreInf(string publishedInf) {
            StringBuilder store = new StringBuilder(4096); int required;
            if (!SetupGetInfDriverStoreLocation(publishedInf, IntPtr.Zero, null, store, store.Capacity, out required)) {
                int error = Marshal.GetLastWin32Error();
                if (error == 2 || error == 1168) return null;
                throw new Win32Exception(error, "Finding driver store package failed");
            }
            return store.ToString();
        }
        public static string FindPublishedInf(string sourceInf) {
            // SetupGetInfDriverStoreLocation accepts a published/system INF or
            // driver-store path, not an arbitrary extracted installer INF.
            // Find a content match first, then resolve that published name and
            // verify the complete INF/DLL/CAT package before using its identity.
            string infDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "INF");
            string sourceDirectory = Path.GetDirectoryName(Path.GetFullPath(sourceInf));
            string driverName = Path.GetFileNameWithoutExtension(sourceInf);
            string match = null;
            foreach (string published in Directory.GetFiles(infDirectory, "oem*.inf")) {
                if (!SameFileContents(sourceInf, published)) continue;
                string storeInf = FindStoreInf(published);
                if (storeInf == null || !SameFileContents(sourceInf, storeInf)) continue;
                string storeDirectory = Path.GetDirectoryName(storeInf);
                bool samePackage = true;
                foreach (string extension in new string[] { ".dll", ".cat" }) {
                    string member = driverName + extension;
                    if (!SameFileContents(Path.Combine(sourceDirectory, member), Path.Combine(storeDirectory, member))) { samePackage = false; break; }
                }
                if (!samePackage) continue;
                if (match != null) throw new InvalidOperationException("More than one published driver package matches the full payload. No package ownership was assumed.");
                match = Path.GetFileName(published);
            }
            return match;
        }
    }
}
'@
}

function Write-SetupLog([string]$Message) {
    Write-Host $Message
    if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value ('{0:u} {1}' -f [DateTime]::UtcNow, $Message) -Encoding UTF8 }
}

function Initialize-SetupLog([string]$StatePath, [string]$Action) {
    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($StatePath))
    if ($Action -in @('Install', 'Uninstall', 'Finalize')) {
        Assert-SetupAdministrator
        Protect-SetupStateFolder $StatePath
    } else { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $script:LogPath = Join-Path $directory ('setup-driver-{0}-{1}-{2}.log' -f $Action.ToLowerInvariant(), [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'), [Guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $script:LogPath -Value 'WinSideUSB driver setup' -Encoding UTF8
    return $script:LogPath
}

function Protect-SetupStateFolder([string]$StatePath) {
    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($StatePath))
    $cursorPath = $directory
    while (-not (Test-Path -LiteralPath $cursorPath)) { $cursorPath = Split-Path -Parent $cursorPath }
    $cursor = Get-Item -LiteralPath $cursorPath -Force
    while ($cursor) {
        if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The setup state path must not contain a junction or symbolic link.' }
        $cursor = $cursor.Parent
    }
    if (Test-Path -LiteralPath $directory) {
        Assert-SetupTrustedStateItem $directory
    } else { New-Item -ItemType Directory -Path $directory | Out-Null }
    foreach ($file in @($StatePath, ($StatePath + '.tmp'), (Join-Path $directory 'setup-result.json'), (Join-Path $directory 'setup-result.txt'))) {
        if (Test-Path -LiteralPath $file) { Assert-SetupTrustedStateItem $file }
    }
    $acl = New-SetupDirectoryAcl
    Set-Acl -LiteralPath $directory -AclObject $acl
}

function New-SetupDirectoryAcl {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    # UMDF has a restricted driver-host token. Both its service identity and
    # restricted UD SID need read/traverse rights to consume the display XML.
    foreach ($entry in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'), @('S-1-5-19', 'ReadAndExecute'), @('S-1-5-84-0-0-0-0-0', 'ReadAndExecute'))) {
        $identity = New-Object Security.Principal.SecurityIdentifier($entry[0])
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, $entry[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    return $acl
}

function Protect-SetupDisplayConfiguration([string]$Directory) {
    Protect-SetupStateFolder (Join-Path $Directory 'config-state.json')
    Set-Acl -LiteralPath $Directory -AclObject (New-SetupDirectoryAcl)
}

function Assert-SetupTrustedStateItem([string]$Path, [switch]$AllowTrustedInstaller, [switch]$AncestorOnly) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Saved setup files must not be symbolic links or junctions.' }
    $acl = Get-Acl -LiteralPath $Path
    $trusted = @('S-1-5-18', 'S-1-5-32-544')
    if ($AllowTrustedInstaller) { $trusted += 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' }
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'The setup state path has an untrusted owner. No saved driver ownership data was used.' }
    $writeRights = [Security.AccessControl.FileSystemRights]'WriteData,AppendData,WriteAttributes,WriteExtendedAttributes,DeleteSubdirectoriesAndFiles,Delete,ChangePermissions,TakeOwnership'
    if ($AncestorOnly) { $writeRights = [Security.AccessControl.FileSystemRights]'DeleteSubdirectoriesAndFiles,Delete,ChangePermissions,TakeOwnership' }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $trusted -and ($rule.FileSystemRights -band $writeRights)) {
            throw 'The setup state path allows non-administrator changes. No saved driver ownership data was used.'
        }
    }
}

function Assert-SetupInstallLocation([string]$InstallDir) {
    if (-not $InstallDir -or $InstallDir -notmatch '^[A-Za-z]:\\') { throw 'Install WinSideUSB in a protected local application directory, such as Program Files.' }
    $fullPath = [IO.Path]::GetFullPath($InstallDir)
    $cursor = $fullPath
    while (-not (Test-Path -LiteralPath $cursor)) { $cursor = Split-Path -Parent $cursor }
    $checkedBase = $cursor
    while ($cursor) {
        Assert-SetupTrustedStateItem $cursor -AllowTrustedInstaller -AncestorOnly:($cursor -ne $checkedBase)
        $cursor = Split-Path -Parent $cursor
    }
}

function Assert-SetupAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Driver setup requires an administrator. Run the setup EXE and accept the Windows elevation prompt.' }
}

function Test-SetupPlatform {
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'This driver package requires x64 Windows and 64-bit PowerShell.' }
    $build = [int](Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber)
    if ($build -lt 22000) { throw 'The current WinSideUSB driver requires Windows 11 (build 22000 or newer).' }
}

function Get-SetupSecurityState {
    Initialize-SetupNative
    $secureBoot = 'Unknown'
    try { if (Confirm-SecureBootUEFI) { $secureBoot = 'On' } else { $secureBoot = 'Off' } }
    catch {
        # Legacy BIOS has no Secure Boot. Other failures are not permission to proceed.
        if ($_.FullyQualifiedErrorId -match 'PlatformNotSupported|CmdletNotSupported|NotSupported') { $secureBoot = 'Unavailable' }
        elseif ($_.Exception -is [PlatformNotSupportedException]) { $secureBoot = 'Unavailable' }
    }
    return [pscustomobject]@{ TestSigning = [WinSideUSB.SetupNative]::TestSigningEnabled(); SecureBoot = $secureBoot }
}

function Test-SetupPackage([string]$PackageDir, [string]$DriverMode = 'Signed', [string]$CertificatePath, [switch]$SkipMachineChecks) {
    if (-not $SkipMachineChecks) { Test-SetupPlatform }
    if (-not $PackageDir) { throw 'A driver package folder is required.' }
    $folder = [IO.Path]::GetFullPath($PackageDir)
    $driverName = if ($DriverMode -eq 'Signed') { 'MttVDD' } else { 'IddSampleDriver' }
    $hardwareId = if ($DriverMode -eq 'Signed') { 'Root\MttVDD' } else { 'Root\WinSideUSBVirtualDisplay' }
    $inf = Join-Path $folder "$driverName.inf"
    $cat = Join-Path $folder "$driverName.cat"
    $dll = Join-Path $folder "$driverName.dll"
    foreach ($file in @($inf, $cat, $dll)) { if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "The driver package is incomplete: $file" } }
    $hardwarePattern = '(?im)^\s*[^;\r\n]+,\s*' + [regex]::Escape($hardwareId) + '\s*(?:;[^\r\n]*)?\r?$'
    if ((Get-Content -LiteralPath $inf -Raw) -notmatch $hardwarePattern) { throw 'The driver INF does not support the expected hardware ID.' }
    if ($DriverMode -eq 'Signed') {
        foreach ($name in $script:SignedVendorHashes.Keys) {
            if ((Get-FileHash -LiteralPath (Join-Path $folder $name) -Algorithm SHA256).Hash -ne $script:SignedVendorHashes[$name]) { throw "The upstream $name differs from the approved unchanged Virtual Display Driver 25.7.23 package." }
        }
    }
    Initialize-SetupNative
    [WinSideUSB.SetupNative]::VerifyCatalogMembers($cat, @($inf, $dll))
    $signature = Get-AuthenticodeSignature -LiteralPath $cat
    if (-not $signature.SignerCertificate) { throw 'The driver catalog has no signing certificate.' }
    $certificate = $null
    if ($DriverMode -in @('Release', 'Signed')) {
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -eq $signature.SignerCertificate.Issuer) {
            throw 'The release driver catalog must have a valid trusted release signature. A self-signed development certificate cannot be used for a release installer.'
        }
        if ($DriverMode -eq 'Signed' -and (Get-AuthenticodeSignature -LiteralPath $dll).Status -ne 'Valid') { throw 'The upstream driver DLL must retain its trusted Authenticode signature.' }
    } else {
        if (-not $SkipMachineChecks) {
            $security = Get-SetupSecurityState
            if (-not $security.TestSigning -or $security.SecureBoot -notin @('Off', 'Unavailable')) {
                throw 'This is a developer preview driver. It requires active Windows test signing and Secure Boot off before setup can continue. Setup does not change these security settings. Use a trusted release build for ordinary installation.'
            }
        }
        if (-not $CertificatePath -or -not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) { throw 'The developer preview signing certificate (.cer) is missing.' }
        $certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2([IO.Path]::GetFullPath($CertificatePath))
        if ($certificate.Thumbprint -ne $signature.SignerCertificate.Thumbprint) { throw 'The developer certificate does not match the signed driver catalog.' }
        if ([DateTime]::Now -lt $certificate.NotBefore -or [DateTime]::Now -gt $certificate.NotAfter) { throw 'The developer signing certificate is not currently valid. Rebuild and sign the package.' }
    }
    return [pscustomobject]@{ InfPath = $inf; CatalogPath = $cat; Certificate = $certificate; HardwareId = $hardwareId; SignerThumbprint = $signature.SignerCertificate.Thumbprint }
}

function New-SetupState {
    return [pscustomobject]@{ SchemaVersion = 1; ProductId = 'WinSideUSB'; Installed = $false; DeviceIds = @(); Packages = @(); Certificates = @(); SharedCertificates = @(); SignedConfig = $null; Service = $null; CurrentPublishedInf = ''; DriverMode = ''; PendingRestart = $false; PendingRemovalBootId = ''; LastUpdatedUtc = '' }
}

function Read-SetupState([string]$StatePath) {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return New-SetupState }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ($state.SchemaVersion -ne 1 -or $state.ProductId -ne 'WinSideUSB') { throw 'The saved setup state is not a supported WinSideUSB ownership record.' }
    if (-not ($state.PSObject.Properties.Name -contains 'PendingRemovalBootId')) { $state | Add-Member NoteProperty PendingRemovalBootId '' }
    if (-not ($state.PSObject.Properties.Name -contains 'SharedCertificates')) { $state | Add-Member NoteProperty SharedCertificates @() }
    if (-not ($state.PSObject.Properties.Name -contains 'SignedConfig')) { $state | Add-Member NoteProperty SignedConfig $null }
    if (-not ($state.PSObject.Properties.Name -contains 'Service')) { $state | Add-Member NoteProperty Service $null }
    if ($state.SignedConfig -and -not ($state.SignedConfig.PSObject.Properties.Name -contains 'RegistryKeys')) {
        $state.SignedConfig | Add-Member NoteProperty RegistryKeys @()
    }
    $devicePattern = if ($state.DriverMode -eq 'Signed') { '^ROOT\\MTTVDD\\[A-Z0-9&]+$' } else { '^ROOT\\WINSIDEUSBVIRTUALDISPLAY\\[A-Z0-9&]+$' }
    foreach ($id in $state.DeviceIds) { if ($id -notmatch $devicePattern) { throw 'The saved state contains an invalid device instance ID.' } }
    foreach ($package in $state.Packages) {
        if ($package.PublishedInf -notmatch '^oem[0-9]+\.inf$' -or $package.InfSha256 -notmatch '^[0-9A-F]{64}$') { throw 'The saved state contains an invalid driver package ownership record.' }
    }
    foreach ($certificate in $state.Certificates) {
        if ($certificate.Store -notin @('Root', 'TrustedPublisher') -or $certificate.Thumbprint -notmatch '^[0-9A-F]{40}$') { throw 'The saved state contains an invalid certificate ownership record.' }
    }
    $state.DeviceIds = @($state.DeviceIds); $state.Packages = @($state.Packages); $state.Certificates = @($state.Certificates)
    return $state
}

function Save-SetupState($State, [string]$StatePath) {
    $State.LastUpdatedUtc = [DateTime]::UtcNow.ToString('o')
    $temporary = $StatePath + '.tmp'
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $StatePath -Force
}

function Get-SetupPublishedInf([string]$InfPath) { Initialize-SetupNative; return [WinSideUSB.SetupNative]::FindPublishedInf($InfPath) }
function Get-SetupDevices { Initialize-SetupNative; return [WinSideUSB.SetupNative]::GetDevices($script:HardwareId) }
function Get-SetupMttDevices { Initialize-SetupNative; return @([WinSideUSB.SetupNative]::GetDevices('Root\MttVDD')) + @([WinSideUSB.SetupNative]::GetDevices('MttVDD')) }
function New-SetupDevice { Initialize-SetupNative; return [WinSideUSB.SetupNative]::CreateDevice($script:HardwareId, ($script:HardwareId -eq 'Root\MttVDD')) }
function Connect-SetupDriver([string]$InfPath) { Initialize-SetupNative; return [WinSideUSB.SetupNative]::BindDriver($InfPath, $script:HardwareId) }
function Disable-SetupDevice([string]$InstanceId) { Initialize-SetupNative; return [WinSideUSB.SetupNative]::SetDeviceEnabled($InstanceId, $script:HardwareId, $false) }
function Remove-SetupDevice([string]$InstanceId) { Initialize-SetupNative; return [WinSideUSB.SetupNative]::RemoveDevice($InstanceId, $script:HardwareId) }
function Get-SetupInfHash([string]$PublishedInf) { return (Get-FileHash -LiteralPath (Join-Path $env:windir "INF\$PublishedInf") -Algorithm SHA256).Hash }
function Test-SetupInfExists([string]$PublishedInf) { return Test-Path -LiteralPath (Join-Path $env:windir "INF\$PublishedInf") -PathType Leaf }
function Get-SetupBootId { return (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o') }

function Invoke-SetupPnpUtil([string[]]$Arguments) {
    $exe = Join-Path $env:windir 'System32\pnputil.exe'
    $output = & $exe @Arguments 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $output) { Write-SetupLog ([string]$line) }
    if ($code -notin @(0, 3010)) { throw "Windows driver operation failed with exit code $code. See the setup log for details." }
    return ($code -eq 3010)
}

function Test-SetupCertificatePresent([string]$Store, [string]$Thumbprint) { return Test-Path -LiteralPath "Cert:\LocalMachine\$Store\$Thumbprint" }
function Add-SetupCertificate([string]$Store, $Certificate) {
    $certificateStore = New-Object Security.Cryptography.X509Certificates.X509Store($Store, 'LocalMachine')
    try { $certificateStore.Open('ReadWrite'); $certificateStore.Add($Certificate) } finally { $certificateStore.Close() }
}
function Remove-SetupCertificate([string]$Store, [string]$Thumbprint) {
    if (Test-SetupCertificatePresent $Store $Thumbprint) { Remove-Item -LiteralPath "Cert:\LocalMachine\$Store\$Thumbprint" -Force }
}

function Test-SetupCertificateInUse([string]$Thumbprint) {
    # A developer certificate may have been adopted by another package after
    # this setup imported it. Inspect catalog signers without building network
    # certificate chains; preserve trust if any catalog cannot be inspected.
    Add-Type -AssemblyName System.Security
    $repository = Join-Path $env:windir 'System32\DriverStore\FileRepository'
    try {
        foreach ($catalog in Get-ChildItem -LiteralPath $repository -Filter '*.cat' -File -Recurse -ErrorAction Stop) {
            $signed = New-Object Security.Cryptography.Pkcs.SignedCms
            $signed.Decode([IO.File]::ReadAllBytes($catalog.FullName))
            foreach ($signer in $signed.SignerInfos) {
                if ($signer.Certificate -and $signer.Certificate.Thumbprint -eq $Thumbprint) { return $true }
            }
        }
    } catch {
        Write-SetupLog ('Certificate sharing could not be ruled out; trust was preserved. ' + $_.Exception.Message)
        return $true
    }
    return $false
}

function New-SetupDisplayConfiguration([string]$AppSourcePath, [string]$DestinationPath) {
    $source = Get-Content -LiteralPath $AppSourcePath -Raw
    $table = [regex]::Match($source, '(?s)static const iPadDef g_ipadDefs\[\] = \{(.*?)\r?\n\};')
    if (-not $table.Success) { throw 'The iPad mode table was not found; refusing to package an incomplete display configuration.' }
    $sizes = @{}
    foreach ($row in [regex]::Matches($table.Groups[1].Value, '(?m)^\s*\{\s*"iPad[^"]+",.*?,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}')) {
        $width = [int]$row.Groups[1].Value; $height = [int]$row.Groups[2].Value
        $sizes["$width,$height"] = @($width, $height)
        # Half-size NV12 frames need even dimensions, including iPad mini's 2266px width.
        $halfWidth = ([int][Math]::Floor($width / 2.0)) -band -2
        $halfHeight = ([int][Math]::Floor($height / 2.0)) -band -2
        $sizes["$halfWidth,$halfHeight"] = @($halfWidth, $halfHeight)
    }
    foreach ($fallback in [regex]::Matches($source, 'AddModeOption\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)')) {
        $width = [int]$fallback.Groups[1].Value; $height = [int]$fallback.Groups[2].Value
        $sizes["$width,$height"] = @($width, $height)
    }
    if ($sizes.Count -lt 10) { throw 'The generated display configuration has too few iPad resolutions.' }
    $xml = New-Object Xml.XmlDocument
    $null = $xml.AppendChild($xml.CreateXmlDeclaration('1.0', 'utf-8', $null))
    $root = $xml.CreateElement('vdd_settings'); $null = $xml.AppendChild($root)
    foreach ($block in @(@('monitors', 'count', '1'), @('gpu', 'friendlyname', 'default'))) {
        $parent = $xml.CreateElement($block[0]); $child = $xml.CreateElement($block[1]); $child.InnerText = $block[2]
        $null = $parent.AppendChild($child); $null = $root.AppendChild($parent)
    }
    $global = $xml.CreateElement('global')
    foreach ($rate in @('60', '120')) { $child = $xml.CreateElement('g_refresh_rate'); $child.InnerText = $rate; $null = $global.AppendChild($child) }
    $null = $root.AppendChild($global)
    $resolutions = $xml.CreateElement('resolutions')
    foreach ($size in ($sizes.Values | Sort-Object { $_[0] } -Descending)) {
        $resolution = $xml.CreateElement('resolution')
        foreach ($pair in @(@('width', [string]$size[0]), @('height', [string]$size[1]))) {
            $child = $xml.CreateElement($pair[0]); $child.InnerText = $pair[1]; $null = $resolution.AppendChild($child)
        }
        $null = $resolutions.AppendChild($resolution)
    }
    $null = $root.AppendChild($resolutions)
    $options = $xml.CreateElement('options')
    foreach ($name in @('CustomEdid', 'PreventSpoof', 'EdidCeaOverride', 'SDR10bit', 'HDRPlus', 'logging', 'debuglogging', 'HardwareCursor')) {
        $child = $xml.CreateElement($name); $child.InnerText = if ($name -eq 'HardwareCursor') { 'true' } else { 'false' }
        $null = $options.AppendChild($child)
    }
    $null = $root.AppendChild($options)
    $writerSettings = New-Object Xml.XmlWriterSettings
    $writerSettings.Indent = $true; $writerSettings.Encoding = New-Object Text.UTF8Encoding($false)
    $writer = [Xml.XmlWriter]::Create($DestinationPath, $writerSettings)
    try { $xml.Save($writer) } finally { $writer.Dispose() }
    return $sizes.Count
}

function Get-SetupService {
    return Get-CimInstance -ClassName Win32_Service -Filter "Name='WinSideUSBDisplayService'" -ErrorAction Stop
}

function Get-SetupServiceExecutable($Service) {
    $path = [Environment]::ExpandEnvironmentVariables($Service.PathName)
    if ($path -match '^"([^"]+)"$') { return [IO.Path]::GetFullPath($Matches[1]) }
    if ($path -match '^[^"]+\.exe$') { return [IO.Path]::GetFullPath($path) }
    throw 'The display service has an unexpected executable command line.'
}

function Assert-SetupExclusiveMttState($State) {
    $foreign = @(Get-SetupMttDevices | Where-Object { $_.InstanceId -notin @($State.DeviceIds) })
    if ($foreign.Count -gt 0) { throw 'Another Virtual Display Driver (MttVDD) installation is present. Remove that installation before using WinSideUSB setup; its devices and global configuration were preserved.' }
    if (@(Get-SetupMttDevices).Count -gt 1) { throw 'More than one managed MttVDD device is present. Setup requires one exclusive virtual display.' }
    $service = Get-SetupService
    if ($service -and (-not $State.Service -or -not $State.Service.Owned -or (Get-SetupServiceExecutable $service) -ne $State.Service.BinaryPath)) {
        throw 'A display service with the same name belongs to another installation. It was preserved.'
    }
}

function Get-SetupInstalledStatePath { return Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WinSideUSB\setup-state.json' }

function Get-SetupRegistryAcl([string]$KeyPath) {
    # Windows PowerShell 5.1 Get-Acl -LiteralPath can report existing registry
    # keys as missing. Read the descriptor from the literal RegistryKey instead.
    $key = Get-Item -LiteralPath $KeyPath
    try { return $key.GetAccessControl() }
    finally { $key.Close() }
}

function Get-SetupRegistryValue([string]$KeyPath, [string]$Name) {
    if (-not (Test-Path -LiteralPath $KeyPath)) { return [pscustomobject]@{ KeyExisted = $false; Existed = $false; Kind = 'String'; Value = $null; KeySddl = '' } }
    $key = Get-Item -LiteralPath $KeyPath
    try {
        $existed = $key.GetValueNames() -contains $Name
        $kind = if ($existed) { [string]$key.GetValueKind($Name) } else { 'String' }
        $value = if ($existed) { $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null }
        return [pscustomobject]@{ KeyExisted = $true; Existed = $existed; Kind = $kind; Value = $value; KeySddl = (Get-SetupRegistryAcl $KeyPath).GetSecurityDescriptorSddlForm('All') }
    } finally { $key.Close() }
}

function Assert-SetupTrustedRegistryAcl($Acl) {
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    if ($Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'The driver configuration registry key has an untrusted owner.' }
    foreach ($rule in $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        # CREATOR OWNER is Windows' inheritance placeholder, not a standard
        # user's SID. Its inheritable grant on SOFTWARE is normal; the actual
        # trusted owner and effective writer SIDs are still checked here.
        if ($rule.IdentityReference.Value -eq 'S-1-3-0' -and ($rule.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ContainerInherit)) { continue }
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $trusted -and ($rule.RegistryRights -band [Security.AccessControl.RegistryRights]'SetValue,CreateSubKey,Delete,ChangePermissions,TakeOwnership')) { throw 'The driver configuration registry key allows non-administrator changes.' }
    }
}

function New-SetupRegistryAcl {
    $acl = New-Object Security.AccessControl.RegistrySecurity
    $acl.SetAccessRuleProtection($true, $false); $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($entry in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadKey'), @('S-1-5-19', 'ReadKey'), @('S-1-5-84-0-0-0-0-0', 'ReadKey'))) {
        $rule = New-Object Security.AccessControl.RegistryAccessRule((New-Object Security.Principal.SecurityIdentifier($entry[0])), $entry[1], 'ContainerInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    return $acl
}

function Protect-SetupRegistryKey([string]$KeyPath) {
    $cursor = $KeyPath
    while (-not (Test-Path -LiteralPath $cursor)) { $cursor = Split-Path -Parent $cursor }
    while ($cursor -and $cursor -ne 'HKLM:' -and $cursor -ne 'HKLM:\') {
        Assert-SetupTrustedRegistryAcl (Get-SetupRegistryAcl $cursor)
        $cursor = Split-Path -Parent $cursor
    }
    if (Test-Path -LiteralPath $KeyPath) {
        $acl = Get-SetupRegistryAcl $KeyPath
        # Preserve existing trusted permissions and add only the restricted
        # UMDF read grants; setup records and later restores the previous ACL.
        foreach ($sid in @('S-1-5-19', 'S-1-5-84-0-0-0-0-0')) {
            $acl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'ReadKey', 'ContainerInherit', 'None', 'Allow')))
        }
    } else {
        New-Item -Path $KeyPath -Force | Out-Null
        # Registry Set-Acl cannot assign the owner through its write handle.
        # The elevated creator already supplies a trusted owner; apply only
        # our DACL and preserve that owner/group instead of requesting it again.
        $acl = Get-SetupRegistryAcl $KeyPath
        Assert-SetupTrustedRegistryAcl $acl
        $desired = New-SetupRegistryAcl
        $acl.SetSecurityDescriptorSddlForm($desired.GetSecurityDescriptorSddlForm('Access'), [Security.AccessControl.AccessControlSections]::Access)
    }
    Set-Acl -LiteralPath $KeyPath -AclObject $acl
}

function Set-SetupOwnedRegistryValue($State, [string]$StatePath, [string]$KeyPath, [string]$Name, $Value, [string]$Kind = 'String') {
    $record = @($State.SignedConfig.Registry | Where-Object { $_.KeyPath -eq $KeyPath -and $_.Name -eq $Name }) | Select-Object -First 1
    if (-not $record) {
        $previous = Get-SetupRegistryValue $KeyPath $Name
        $record = [pscustomobject]@{ KeyPath = $KeyPath; Name = $Name; KeyExisted = $previous.KeyExisted; PreviousKeySddl = $previous.KeySddl; Existed = $previous.Existed; PreviousKind = $previous.Kind; PreviousValue = $previous.Value; InstalledValue = $Value; InstalledKind = $Kind }
        $State.SignedConfig.Registry += $record
    } else { $record.InstalledValue = $Value; $record.InstalledKind = $Kind }
    $keyRecord = @($State.SignedConfig.RegistryKeys | Where-Object { $_.KeyPath -eq $KeyPath }) | Select-Object -First 1
    if (-not $keyRecord) {
        $snapshot = Get-SetupRegistryValue $KeyPath $Name
        $keyRecord = [pscustomobject]@{ KeyPath = $KeyPath; Existed = $snapshot.KeyExisted; PreviousSddl = $snapshot.KeySddl; InstalledSddl = '' }
        $State.SignedConfig.RegistryKeys += $keyRecord
    }
    Save-SetupState $State $StatePath
    Protect-SetupRegistryKey $KeyPath
    $keyRecord.InstalledSddl = (Get-SetupRegistryAcl $KeyPath).GetSecurityDescriptorSddlForm('All')
    Save-SetupState $State $StatePath
    New-ItemProperty -LiteralPath $KeyPath -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
}

function Restore-SetupRegistryValue($Record) {
    $current = Get-SetupRegistryValue $Record.KeyPath $Record.Name
    if (-not $current.Existed) { return }
    if ($current.Kind -ne $Record.InstalledKind -or [string]$current.Value -ne [string]$Record.InstalledValue) {
        Write-SetupLog "Registry value $($Record.KeyPath)\$($Record.Name) was changed by another installation and was preserved."
        return
    }
    if ($Record.Existed) { New-ItemProperty -LiteralPath $Record.KeyPath -Name $Record.Name -Value $Record.PreviousValue -PropertyType $Record.PreviousKind -Force | Out-Null }
    else { Remove-ItemProperty -LiteralPath $Record.KeyPath -Name $Record.Name }
}

function Install-SetupSignedConfiguration($State, [string]$StatePath, [string]$PackageDir, [string]$InstallDir, [string]$ServicePath) {
    if (-not $InstallDir -or -not $ServicePath -or -not (Test-Path -LiteralPath $ServicePath -PathType Leaf)) { throw 'The signed driver setup requires the compiled WinSideUSB display service and installation directory.' }
    $InstallDir = [IO.Path]::GetFullPath($InstallDir)
    Assert-SetupInstallLocation $InstallDir
    $configPath = Join-Path (Split-Path -Parent $StatePath) 'display-config'
    $xmlPath = Join-Path $PackageDir 'vdd_settings.xml'
    if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) { throw 'The packaged iPad display configuration is missing.' }
    $xml = New-Object Xml.XmlDocument; $xml.Load($xmlPath)
    if ($xml.vdd_settings.monitors.count -ne '1' -or @($xml.vdd_settings.resolutions.resolution).Count -lt 10) { throw 'The iPad display configuration is incomplete.' }
    if (-not $State.SignedConfig) {
        if (Test-Path -LiteralPath $configPath) { throw 'An unowned display configuration directory already exists. It was preserved.' }
        $State.SignedConfig = [pscustomobject]@{ Directory = $configPath; XmlPath = (Join-Path $configPath 'vdd_settings.xml'); XmlSha256 = ''; Registry = @(); RegistryKeys = @() }
        Save-SetupState $State $StatePath
    }
    if ($State.Service -and $State.Service.BinaryPath -ne (Join-Path $InstallDir 'WinSideUSBDisplayService.exe')) { throw 'Uninstall the existing WinSideUSB installation before choosing another installation folder.' }
    Protect-SetupDisplayConfiguration $configPath
    if (Test-Path -LiteralPath $State.SignedConfig.XmlPath) { Assert-SetupTrustedStateItem $State.SignedConfig.XmlPath }
    Copy-Item -LiteralPath $xmlPath -Destination $State.SignedConfig.XmlPath -Force
    $State.SignedConfig.XmlSha256 = (Get-FileHash -LiteralPath $State.SignedConfig.XmlPath -Algorithm SHA256).Hash
    $State.Service = [pscustomobject]@{ Name = 'WinSideUSBDisplayService'; BinaryPath = (Join-Path $InstallDir 'WinSideUSBDisplayService.exe'); ExpectedHash = (Get-FileHash -LiteralPath $ServicePath -Algorithm SHA256).Hash; Owned = [bool]($State.Service -and $State.Service.Owned); Registered = [bool]($State.Service -and $State.Service.Registered) }
    Save-SetupState $State $StatePath
    $globalKey = 'HKLM:\SOFTWARE\MikeTheTech\VirtualDisplayDriver'
    Set-SetupOwnedRegistryValue $State $StatePath $globalKey 'VDDPATH' $configPath
    foreach ($name in @('CUSTOMEDID', 'PREVENTMONITORSPOOF', 'EDIDCEAOVERRIDE', 'SDR10BIT', 'HDRPLUS', 'LOGS', 'DEBUGLOGS', 'HARDWARECURSOR')) {
        $value = if ($name -eq 'HARDWARECURSOR') { 1 } else { 0 }
        Set-SetupOwnedRegistryValue $State $StatePath $globalKey $name $value 'DWord'
    }
    Set-SetupOwnedRegistryValue $State $StatePath 'HKLM:\SOFTWARE\WinSideUSB' 'ConfigPath' $configPath
    Set-SetupOwnedRegistryValue $State $StatePath 'HKLM:\SOFTWARE\WinSideUSB' 'InstallDir' $InstallDir
}

function Stop-SetupOwnedService($State) {
    if (-not $State.Service -or -not $State.Service.Owned) { return }
    $service = Get-SetupService
    if (-not $service) { return }
    if ((Get-SetupServiceExecutable $service) -ne $State.Service.BinaryPath) { throw 'The saved display service executable changed; that service was preserved.' }
    $controller = Get-Service -Name 'WinSideUSBDisplayService' -ErrorAction Stop
    if ($controller.Status -ne 'Stopped') { Stop-Service -Name $controller.Name -ErrorAction Stop; $controller.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20)) }
}

function Invoke-SetupServiceCommand([string[]]$Arguments) {
    $output = & (Join-Path $env:windir 'System32\sc.exe') @Arguments 2>&1
    $code = $LASTEXITCODE; foreach ($line in $output) { Write-SetupLog ([string]$line) }
    if ($code -notin @(0, 1072)) { throw "Windows service operation failed with exit code $code." }
    return ($code -eq 1072)
}

function Complete-SetupSignedService($State, [string]$StatePath) {
    if (-not $State.Installed -or -not $State.Service -or $State.DeviceIds.Count -ne 1) { throw 'The managed display installation is incomplete.' }
    Assert-SetupExclusiveMttState $State
    $binary = $State.Service.BinaryPath
    Assert-SetupInstallLocation (Split-Path -Parent $binary)
    foreach ($path in @((Split-Path -Parent $binary), $binary, (Join-Path (Split-Path -Parent $binary) 'WinSideUSB.exe'))) { Assert-SetupTrustedStateItem $path -AllowTrustedInstaller }
    if ((Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash -ne $State.Service.ExpectedHash) { throw 'The installed display service does not match the packaged executable.' }
    $service = Get-SetupService
    if (-not $service) {
        $State.Service.Owned = $true; Save-SetupState $State $StatePath
        New-Service -Name 'WinSideUSBDisplayService' -DisplayName 'WinSideUSB Display Service' -BinaryPathName ('"' + $binary + '"') -StartupType Automatic -Description 'Controls the WinSideUSB virtual display while an iPad is connected.' | Out-Null
    } else { Set-Service -Name 'WinSideUSBDisplayService' -StartupType Automatic }
    $State.Service.Registered = $true; Save-SetupState $State $StatePath
    # A restarted broker disables its owned node before accepting connections.
    # Recover after a crash rather than leaving an orphaned desktop enabled.
    if (Invoke-SetupServiceCommand @('failure', 'WinSideUSBDisplayService', 'reset=', '86400', 'actions=', 'restart/1000/restart/5000/restart/10000')) { throw 'Restart Windows before finishing display service setup.' }
    if (Invoke-SetupServiceCommand @('failureflag', 'WinSideUSBDisplayService', '1')) { throw 'Restart Windows before finishing display service setup.' }
    if ($State.PendingRestart) { return [pscustomobject]@{ ExitCode = 3010; Message = 'WinSideUSB was installed. Restart Windows to finish preparing the virtual display.' } }
    Start-Service -Name 'WinSideUSBDisplayService'
    (Get-Service -Name 'WinSideUSBDisplayService').WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    $devices = @(Get-SetupDevices)
    if ($devices.Count -ne 1 -or $devices[0].InstanceId -ne $State.DeviceIds[0] -or $devices[0].ProblemCode -ne 22 -or ($devices[0].Status -band 8)) { throw 'The display service did not leave its managed virtual display disabled.' }
    return [pscustomobject]@{ ExitCode = 0; Message = 'WinSideUSB is ready. The virtual display stays off until an iPad connection is established.' }
}

function Remove-SetupSignedService($State, [string]$StatePath) {
    Stop-SetupOwnedService $State
    if ($State.Service -and $State.Service.Owned -and (Get-SetupService)) {
        $reboot = Invoke-SetupServiceCommand @('delete', 'WinSideUSBDisplayService')
        if ($reboot -or (Get-SetupService)) { $State.PendingRemovalBootId = Get-SetupBootId; $State.PendingRestart = $true; Save-SetupState $State $StatePath; return $true }
    }
    $State.Service = $null; Save-SetupState $State $StatePath
    return $false
}

function Remove-SetupSignedConfiguration($State, [string]$StatePath) {
    if (-not $State.SignedConfig) { return }
    foreach ($record in @($State.SignedConfig.Registry)) {
        Restore-SetupRegistryValue $record
        $State.SignedConfig.Registry = @($State.SignedConfig.Registry | Where-Object { $_.KeyPath -ne $record.KeyPath -or $_.Name -ne $record.Name })
        Save-SetupState $State $StatePath
    }
    foreach ($record in @($State.SignedConfig.RegistryKeys)) {
        if (Test-Path -LiteralPath $record.KeyPath) {
            if ($record.Existed) {
                $acl = Get-SetupRegistryAcl $record.KeyPath
                if ($record.InstalledSddl -and $acl.GetSecurityDescriptorSddlForm('All') -eq $record.InstalledSddl) {
                    # Setup only changed the DACL on an existing key. Keep its
                    # owner/group intact rather than requesting WRITE_OWNER
                    # while restoring the permissions we actually changed.
                    $restored = $acl
                    $restored.SetSecurityDescriptorSddlForm($record.PreviousSddl, [Security.AccessControl.AccessControlSections]::Access)
                    Set-Acl -LiteralPath $record.KeyPath -AclObject $restored
                } else { Write-SetupLog "Registry permissions $($record.KeyPath) changed after setup and were preserved." }
            } else {
                $key = Get-Item -LiteralPath $record.KeyPath
                if ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) { Remove-Item -LiteralPath $record.KeyPath }
            }
        }
        $State.SignedConfig.RegistryKeys = @($State.SignedConfig.RegistryKeys | Where-Object { $_.KeyPath -ne $record.KeyPath })
        Save-SetupState $State $StatePath
    }
    if (Test-Path -LiteralPath $State.SignedConfig.XmlPath) {
        Assert-SetupTrustedStateItem $State.SignedConfig.XmlPath
        if ((Get-FileHash -LiteralPath $State.SignedConfig.XmlPath -Algorithm SHA256).Hash -ne $State.SignedConfig.XmlSha256) { throw 'The installed display XML was modified; it was preserved for review.' }
        Remove-Item -LiteralPath $State.SignedConfig.XmlPath -Force
    }
    if ((Test-Path -LiteralPath $State.SignedConfig.Directory) -and @(Get-ChildItem -LiteralPath $State.SignedConfig.Directory -Force).Count -eq 0) { Remove-Item -LiteralPath $State.SignedConfig.Directory }
    $State.SignedConfig = $null; Save-SetupState $State $StatePath
}

function Remove-SetupOwnedResources($State, [string]$StatePath, [string[]]$DeviceIds, [object[]]$Packages, [object[]]$Certificates) {
    $errors = New-Object Collections.Generic.List[string]
    $reboot = $false
    # Obtain the boot marker before removal. A failed query must not leave a
    # successful native removal with no way to distinguish a same-boot retry.
    $bootId = Get-SetupBootId
    foreach ($id in $DeviceIds) {
        try {
            $deviceReboot = Remove-SetupDevice $id
            $reboot = $deviceReboot -or $reboot
            if (-not $deviceReboot) { $State.DeviceIds = @($State.DeviceIds | Where-Object { $_ -ne $id }) }
            else { $State.PendingRemovalBootId = $bootId }
            Save-SetupState $State $StatePath
        } catch { $errors.Add("Device ${id}: $($_.Exception.Message)"); Write-SetupLog $errors[$errors.Count - 1] }
    }
    foreach ($package in $Packages) {
        try {
            $packageReboot = $false
            if (Test-SetupInfExists $package.PublishedInf) {
                if ((Get-SetupInfHash $package.PublishedInf) -ne $package.InfSha256) { throw 'The published INF contents have changed; the package was preserved.' }
                # No /force or /uninstall: Windows must refuse packages still used by another device.
                $packageReboot = Invoke-SetupPnpUtil @('/delete-driver', $package.PublishedInf)
                $reboot = $packageReboot -or $reboot
            }
            if (-not $packageReboot) { $State.Packages = @($State.Packages | Where-Object { $_.PublishedInf -ne $package.PublishedInf }) }
            else { $State.PendingRemovalBootId = $bootId }
            Save-SetupState $State $StatePath
        } catch { $errors.Add("Package $($package.PublishedInf): $($_.Exception.Message)"); Write-SetupLog $errors[$errors.Count - 1] }
    }
    # Keep trust until all owned packages are gone, including removals pending restart.
    if ($State.Packages.Count -eq 0 -and $State.DeviceIds.Count -eq 0 -and -not $reboot) {
        foreach ($certificate in $Certificates) {
            try {
                if (Test-SetupCertificateInUse $certificate.Thumbprint) {
                    Write-SetupLog "Certificate $($certificate.Thumbprint) is shared with another package and was preserved."
                    $State.SharedCertificates += $certificate
                } else { Remove-SetupCertificate $certificate.Store $certificate.Thumbprint }
                $State.Certificates = @($State.Certificates | Where-Object { $_.Store -ne $certificate.Store -or $_.Thumbprint -ne $certificate.Thumbprint })
                Save-SetupState $State $StatePath
            } catch { $errors.Add("Certificate $($certificate.Thumbprint): $($_.Exception.Message)"); Write-SetupLog $errors[$errors.Count - 1] }
        }
    }
    $State.PendingRestart = $reboot
    if (-not $reboot) { $State.PendingRemovalBootId = '' }
    Save-SetupState $State $StatePath
    return [pscustomobject]@{ Reboot = $reboot; Errors = @($errors.ToArray()) }
}

function Invoke-SetupDriverAction([string]$Action, [string]$PackageDir, [string]$StatePath, [string]$DriverMode = 'Signed', [string]$CertificatePath = '', [string]$InstallDir = '', [string]$ServicePath = '') {
    if ($Action -eq 'Check') {
        $null = Test-SetupPackage $PackageDir $DriverMode $CertificatePath
        if ($DriverMode -eq 'Signed') {
            $installedStatePath = Get-SetupInstalledStatePath
            $installedState = New-SetupState
            if (Test-Path -LiteralPath $installedStatePath) {
                Assert-SetupTrustedStateItem (Split-Path -Parent $installedStatePath)
                Assert-SetupTrustedStateItem $installedStatePath
                $installedState = Read-SetupState $installedStatePath
            }
            Assert-SetupExclusiveMttState $installedState
            if (-not $ServicePath -or -not (Test-Path -LiteralPath $ServicePath -PathType Leaf)) { throw 'The setup display service payload is missing.' }
            Assert-SetupInstallLocation $InstallDir
        }
        return [pscustomobject]@{ ExitCode = 0; Message = 'Driver prerequisites and signed package checks passed.' }
    }
    Assert-SetupAdministrator
    Protect-SetupStateFolder $StatePath
    $state = Read-SetupState $StatePath
    $script:HardwareId = if (($Action -in @('Uninstall', 'Finalize') -and $state.DriverMode -eq 'Signed') -or ($Action -eq 'Install' -and $DriverMode -eq 'Signed')) { 'Root\MttVDD' } else { 'Root\WinSideUSBVirtualDisplay' }
    if ($state.PendingRemovalBootId -and $state.PendingRemovalBootId -eq (Get-SetupBootId)) {
        $pendingMessage = 'Restart Windows before retrying setup. Removal of the previous virtual display is still pending; certificate trust and its ownership record were preserved.'
        if ($Action -eq 'Install') { throw $pendingMessage }
        return [pscustomobject]@{ ExitCode = 3010; Message = $pendingMessage }
    }
    if ($state.PendingRemovalBootId -and $Action -eq 'Install' -and $DriverMode -ne 'Signed') {
        throw 'Finish the previous uninstall after restarting Windows, then run setup again. Pending removal ownership has been preserved.'
    }
    if ($Action -eq 'Finalize') {
        if ($state.DriverMode -ne 'Signed') { return [pscustomobject]@{ ExitCode = 0; Message = 'Driver setup is complete.' } }
        return Complete-SetupSignedService $state $StatePath
    }
    if ($Action -eq 'Uninstall') {
        if ($state.DriverMode -eq 'Signed') {
            Assert-SetupExclusiveMttState $state
            if (Remove-SetupSignedService $state $StatePath) { return [pscustomobject]@{ ExitCode = 3010; Message = 'Restart Windows to finish removing the display service, then run uninstall again.' } }
        }
        $cleanup = Remove-SetupOwnedResources $state $StatePath @($state.DeviceIds) @($state.Packages) @($state.Certificates)
        if ($cleanup.Errors.Count -gt 0) {
            $errorMessage = 'Driver cleanup did not finish. The ownership record was kept for retry. ' + ($cleanup.Errors -join ' ')
            if ($cleanup.Reboot) { $errorMessage += ' Restart Windows before retrying uninstall.' }
            throw $errorMessage
        }
        if ($cleanup.Reboot) { return [pscustomobject]@{ ExitCode = 3010; Message = 'Restart Windows to finish removing the virtual display. Run uninstall again after restarting to finish certificate cleanup.' } }
        if ($state.DriverMode -eq 'Signed') { Remove-SetupSignedConfiguration $state $StatePath }
        $state.Installed = $false; $state.CurrentPublishedInf = ''; Save-SetupState $state $StatePath
        $message = 'All driver resources created by this setup were removed.'
        if ($state.SharedCertificates.Count -gt 0) { $message = 'The virtual display was removed. Certificate trust needed by other driver packages was preserved.' }
        return [pscustomobject]@{ ExitCode = 0; Message = $message }
    }
    if ($Action -ne 'Install') { throw "Unknown driver setup action: $Action" }
    $package = Test-SetupPackage $PackageDir $DriverMode $CertificatePath
    if ($DriverMode -eq 'Signed') {
        Assert-SetupExclusiveMttState $state
        # Migrate only resources recorded as owned by the previous development
        # installer. Untracked sample devices and certificates remain untouched.
        if (($state.DriverMode -and $state.DriverMode -ne 'Signed') -or $state.PendingRemovalBootId) {
            $script:HardwareId = if ($state.DriverMode -eq 'Signed') { 'Root\MttVDD' } else { 'Root\WinSideUSBVirtualDisplay' }
            if ($state.DriverMode -eq 'Signed' -and (Remove-SetupSignedService $state $StatePath)) { throw 'Restart Windows before retrying setup; the old display service is being removed.' }
            $migration = Remove-SetupOwnedResources $state $StatePath @($state.DeviceIds) @($state.Packages) @($state.Certificates)
            if ($migration.Errors.Count -gt 0 -or $migration.Reboot) { throw ('The previous owned driver could not finish removal. Restart Windows and retry setup. ' + ($migration.Errors -join ' ')) }
            if ($state.DriverMode -eq 'Signed') { Remove-SetupSignedConfiguration $state $StatePath }
            $state.Installed = $false; $state.CurrentPublishedInf = ''; $state.DriverMode = 'Signed'; Save-SetupState $state $StatePath
            $script:HardwareId = 'Root\MttVDD'
        }
        Stop-SetupOwnedService $state
    } elseif ($state.DriverMode -eq 'Signed') { throw 'Uninstall the signed display backend before installing a development driver.' }
    $firstInstall = -not $state.Installed
    $newDevices = @(); $newPackages = @(); $newCertificates = @(); $reboot = $false
    $newSignedConfiguration = ($DriverMode -eq 'Signed' -and -not $state.SignedConfig)
    try {
        # Save an empty record first so a write/permission failure cannot leave untracked resources.
        $state.DriverMode = $DriverMode
        Save-SetupState $state $StatePath
        if ($DriverMode -eq 'Signed') { Install-SetupSignedConfiguration $state $StatePath $PackageDir $InstallDir $ServicePath }
        if ($DriverMode -eq 'Development') {
            foreach ($store in @('Root', 'TrustedPublisher')) {
                if (-not (Test-SetupCertificatePresent $store $package.Certificate.Thumbprint)) {
                    Add-SetupCertificate $store $package.Certificate
                    $owned = [pscustomobject]@{ Store = $store; Thumbprint = $package.Certificate.Thumbprint }
                    $state.Certificates += $owned; $newCertificates += $owned; Save-SetupState $state $StatePath
                }
            }
        }
        $before = Get-SetupPublishedInf $package.InfPath
        $reboot = (Invoke-SetupPnpUtil @('/add-driver', $package.InfPath)) -or $reboot
        $published = Get-SetupPublishedInf $package.InfPath
        if (-not $published -or $published -notmatch '^oem[0-9]+\.inf$') { throw 'Windows did not publish the staged driver package. Installation cannot continue.' }
        if (-not $before -and @($state.Packages | Where-Object { $_.PublishedInf -eq $published }).Count -eq 0) {
            $owned = [pscustomobject]@{ PublishedInf = $published; InfSha256 = Get-SetupInfHash $published }
            $state.Packages += $owned; $newPackages += $owned; Save-SetupState $state $StatePath
        }
        $devices = @(Get-SetupDevices)
        if ($devices.Count -eq 0) {
            $id = New-SetupDevice
            $state.DeviceIds += $id; $newDevices += $id; Save-SetupState $state $StatePath
        }
        $reboot = (Connect-SetupDriver $package.InfPath) -or $reboot
        if ($DriverMode -eq 'Signed') {
            if ($state.DeviceIds.Count -ne 1) { throw 'Setup did not create one exclusive owned display device.' }
            $reboot = (Disable-SetupDevice $state.DeviceIds[0]) -or $reboot
            Set-SetupOwnedRegistryValue $state $StatePath 'HKLM:\SOFTWARE\WinSideUSB' 'ManagedDeviceInstanceId' $state.DeviceIds[0]
        }
        # Driver association and problem codes are numeric/structured; no translated pnputil output is parsed.
        $verified = $false
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            $devices = @(Get-SetupDevices)
            if ($DriverMode -eq 'Signed') {
                $bad = @($devices | Where-Object { $_.PublishedInf -ne $published -or ($_.Status -band 8) -or ($_.ProblemCode -ne 22 -and -not ($reboot -and $_.ProblemCode -eq 14)) })
            } else { $bad = @($devices | Where-Object { $_.PublishedInf -ne $published -or ($_.ProblemCode -ne 0 -and $_.ProblemCode -ne 14) -or ($_.ProblemCode -eq 0 -and -not ($_.Status -band 8) -and -not $reboot -and -not ($_.Status -band 0x100)) }) }
            if ($devices.Count -gt 0 -and $bad.Count -eq 0) {
                if (@($devices | Where-Object { $_.ProblemCode -eq 14 -or ($_.Status -band 0x100) }).Count -gt 0) { $reboot = $true }
                $verified = $true; break
            }
            if ($attempt -lt 4) { Start-Sleep -Milliseconds 500 }
        }
        if (-not $verified) { throw 'Windows did not report a working WinSideUSB driver bound to the staged package. The setup log and Device Manager contain the failure details.' }
        $state.CurrentPublishedInf = $published; $state.DriverMode = $DriverMode; $state.PendingRestart = $reboot; $state.Installed = $true
        Save-SetupState $state $StatePath
        if ($reboot) { return [pscustomobject]@{ ExitCode = 3010; Message = 'The virtual display driver was installed. Restart Windows to finish setup.' } }
        return [pscustomobject]@{ ExitCode = 0; Message = 'The virtual display driver was installed and verified.' }
    } catch {
        $failure = $_.Exception.Message
        Write-SetupLog $failure
        Write-SetupLog $_.ScriptStackTrace
        Write-SetupLog $_.InvocationInfo.PositionMessage
        if ($firstInstall) {
            $cleanup = Remove-SetupOwnedResources $state $StatePath $newDevices $newPackages $newCertificates
            if ($newSignedConfiguration -and $cleanup.Errors.Count -eq 0 -and -not $cleanup.Reboot) {
                try { $null = Remove-SetupSignedService $state $StatePath; Remove-SetupSignedConfiguration $state $StatePath }
                catch { $failure += ' Configuration rollback needs retry: ' + $_.Exception.Message }
            }
            if ($cleanup.Errors.Count -gt 0) { $failure += ' Rollback needs retry: ' + ($cleanup.Errors -join ' ') }
            if ($cleanup.Reboot) { $failure += ' Restart Windows to finish rollback, then run uninstall to finish cleanup.' }
        }
        throw $failure
    }
}

Export-ModuleMember -Function Initialize-SetupLog, Invoke-SetupDriverAction, Test-SetupPackage, New-SetupDisplayConfiguration

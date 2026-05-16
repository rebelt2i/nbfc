using StagWare.FanControl.Plugins;
using StagWare.Hardware;
using System;
using System.ComponentModel.Composition;
using System.Threading;

namespace StagWare.Plugins
{
    [Export(typeof(IEmbeddedController))]
    [FanControlPluginMetadata(
        "StagWare.Plugins.ECThinkPad",
        SupportedPlatforms.Windows,
        SupportedCpuArchitectures.x86 | SupportedCpuArchitectures.x64,
        Priority = 15,
        MinOSVersion = "6.1")]
    public class ECThinkPad : IEmbeddedController, IPortIoProvider
    {
        private const string EcMutexName = "Access_Thinkpad_EC";

        private HardwareMonitor hwMon;
        private ThinkPadEcPortIo portIo;
        private Mutex ecMutex;
        private int ecMutexLockCount;

        public bool IsInitialized { get; private set; }

        public void Initialize()
        {
            if (this.IsInitialized)
            {
                return;
            }

            this.hwMon = HardwareMonitor.Instance;
            if (this.hwMon == null)
            {
                return;
            }

            this.portIo = new ThinkPadEcPortIo();
            if (!this.portIo.Initialize(this))
            {
                return;
            }

            try
            {
                this.ecMutex = new Mutex(false, EcMutexName);
            }
            catch (UnauthorizedAccessException)
            {
                try
                {
                    this.ecMutex = Mutex.OpenExisting(EcMutexName);
                }
                catch
                {
                    return;
                }
            }

            this.IsInitialized = true;
        }

        public bool AcquireLock(int timeout)
        {
            if (!this.hwMon.WaitIsaBusMutex(timeout))
            {
                return false;
            }

            try
            {
                if (this.ecMutex.WaitOne(timeout))
                {
                    this.ecMutexLockCount = 1;
                    return true;
                }
            }
            catch (AbandonedMutexException)
            {
                this.ecMutexLockCount = 1;
                return true;
            }

            this.hwMon.ReleaseIsaBusMutex();
            return false;
        }

        public void ReleaseLock()
        {
            if (this.ecMutexLockCount > 0)
            {
                try
                {
                    this.ecMutex.ReleaseMutex();
                }
                catch
                {
                }

                this.ecMutexLockCount = 0;
            }

            this.hwMon.ReleaseIsaBusMutex();
        }

        public void WriteByte(byte register, byte value)
        {
            this.portIo.WriteByte(register, value);
        }

        public void WriteWord(byte register, ushort value)
        {
            this.portIo.WriteWord(register, value);
        }

        public byte ReadByte(byte register)
        {
            return this.portIo.ReadByte(register);
        }

        public ushort ReadWord(byte register)
        {
            return this.portIo.ReadWord(register);
        }

        public void WritePort(int port, byte value)
        {
            this.hwMon.WriteIoPort(port, value);
        }

        public byte ReadPort(int port)
        {
            return this.hwMon.ReadIoPort(port);
        }

        public void Dispose()
        {
            try
            {
                ReleaseLock();
            }
            catch
            {
            }

            if (this.ecMutex != null)
            {
                this.ecMutex.Dispose();
                this.ecMutex = null;
            }
        }
    }
}

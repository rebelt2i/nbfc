using System;
using System.Threading;

namespace StagWare.Plugins
{
    /// <summary>
    /// ThinkPad EC port access with ACPI type-1 (0x1604/0x1600) and type-2 (0x66/0x62) fallback.
    /// Ported from TPFanCtrl2 portio.cpp.
    /// </summary>
    internal sealed class ThinkPadEcPortIo
    {
        private const int Type1CtrlPort = 0x1604;
        private const int Type1DataPort = 0x1600;
        private const int Type2CtrlPort = 0x66;
        private const int Type2DataPort = 0x62;

        private const byte FlagObf = 0x01;
        private const byte FlagIbf = 0x02;
        private const byte CmdRead = 0x80;
        private const byte CmdWrite = 0x81;

        private const int MaxRetries = 5;
        private const int DefaultTimeout = 1000;

        private IPortIoProvider portIo;
        private int ctrlPort;
        private int dataPort;

        public bool IsInitialized { get; private set; }

        public bool Initialize(IPortIoProvider provider)
        {
            this.portIo = provider;

            if (TryInitializePorts(Type1CtrlPort, Type1DataPort))
            {
                this.IsInitialized = true;
                return true;
            }

            if (TryInitializePorts(Type2CtrlPort, Type2DataPort))
            {
                this.IsInitialized = true;
                return true;
            }

            this.IsInitialized = false;
            return false;
        }

        private bool TryInitializePorts(int ctrl, int data)
        {
            this.ctrlPort = ctrl;
            this.dataPort = data;

            byte unused;
            return TryReadByte(0x2F, out unused);
        }

        public byte ReadByte(byte register)
        {
            byte value = 0;

            for (int i = 0; i < MaxRetries; i++)
            {
                if (TryReadByte(register, out value))
                {
                    return value;
                }
            }

            return value;
        }

        public void WriteByte(byte register, byte value)
        {
            for (int i = 0; i < MaxRetries; i++)
            {
                if (TryWriteByte(register, value))
                {
                    return;
                }
            }
        }

        public ushort ReadWord(byte register)
        {
            byte lo = ReadByte(register);
            byte hi = ReadByte((byte)(register + 1));
            return (ushort)(lo | (hi << 8));
        }

        public void WriteWord(byte register, ushort value)
        {
            WriteByte(register, (byte)value);
            WriteByte((byte)(register + 1), (byte)(value >> 8));
        }

        private bool TryReadByte(byte register, out byte value)
        {
            value = 0;

            if (!WaitForFlags(FlagIbf | FlagObf, false))
            {
                return false;
            }

            if (!WaitForFlags(FlagIbf | FlagObf, false))
            {
                return false;
            }

            this.portIo.WritePort(this.ctrlPort, CmdRead);

            if (!WaitForFlags(FlagIbf | FlagObf, false))
            {
                return false;
            }

            this.portIo.WritePort(this.dataPort, register);

            if (!WaitForFlags(FlagObf, true))
            {
                return false;
            }

            value = this.portIo.ReadPort(this.dataPort);
            return true;
        }

        private bool TryWriteByte(byte register, byte value)
        {
            if (!WaitForFlags(FlagIbf | FlagObf, false))
            {
                return false;
            }

            this.portIo.WritePort(this.ctrlPort, CmdWrite);

            if (!WaitForFlags(FlagIbf | FlagObf, false))
            {
                return false;
            }

            this.portIo.WritePort(this.dataPort, register);

            if (!WaitForFlags(FlagIbf | FlagObf, false))
            {
                return false;
            }

            this.portIo.WritePort(this.dataPort, value);
            return true;
        }

        private bool WaitForFlags(byte flags, bool set, int timeout = DefaultTimeout)
        {
            int elapsed = 0;
            const int sleepTicks = 10;

            while (elapsed < timeout)
            {
                byte data = this.portIo.ReadPort(this.ctrlPort);
                bool idle = (data & (FlagIbf | FlagObf)) == 0;

                if (set)
                {
                    if ((data & flags) != 0)
                    {
                        return true;
                    }
                }
                else if (idle)
                {
                    return true;
                }

                Thread.Sleep(sleepTicks);
                elapsed += sleepTicks;
            }

            return false;
        }
    }
}

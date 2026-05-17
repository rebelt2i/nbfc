using StagWare.FanControl.Configurations;
using StagWare.FanControl.Plugins;
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;

namespace StagWare.FanControl
{
    /// <summary>
    /// Reads ThinkPad EC temperature bytes (e.g. P52: 0x78 CPU, 0x79 GPU) with fallbacks.
    /// </summary>
    internal static class ThinkPadEcTemperature
    {
        private static readonly byte CpuRegister = 0x78;
        private static readonly byte[] GpuRegisters = { 0x79, 0xC0, 0xC1, 0x7A, 0x7B };

        public static bool IsPlausible(int value)
        {
            return value > 0 && value < 125;
        }

        public static int Read(IEmbeddedController ec, FanConfiguration fanConfig)
        {
            if (ec == null || fanConfig == null)
            {
                return -1;
            }

            if (fanConfig.TemperatureRegister > 0)
            {
                int configured = ec.ReadByte((byte)fanConfig.TemperatureRegister);

                if (IsPlausible(configured))
                {
                    return configured;
                }
            }

            int byName = ReadByFanName(ec, fanConfig.FanDisplayName);

            if (IsPlausible(byName))
            {
                return byName;
            }

            if (IsGpuFan(fanConfig.FanDisplayName))
            {
                int gpu = TryReadGpuFromOpenHardware();

                if (IsPlausible(gpu))
                {
                    return gpu;
                }
            }

            return -1;
        }

        public static int ReadByFanName(IEmbeddedController ec, string fanDisplayName)
        {
            if (ec == null)
            {
                return -1;
            }

            if (IsGpuFan(fanDisplayName))
            {
                return ReadFirstPlausible(ec, GpuRegisters);
            }

            if (IsCpuFan(fanDisplayName))
            {
                return ReadRegisterIfPlausible(ec, CpuRegister);
            }

            return -1;
        }

        private static int ReadFirstPlausible(IEmbeddedController ec, IEnumerable<byte> registers)
        {
            foreach (byte register in registers)
            {
                int value = ReadRegisterIfPlausible(ec, register);

                if (value >= 0)
                {
                    return value;
                }
            }

            return -1;
        }

        private static int ReadRegisterIfPlausible(IEmbeddedController ec, byte register)
        {
            int value = ec.ReadByte(register);
            return IsPlausible(value) ? value : -1;
        }

        private static bool IsGpuFan(string fanDisplayName)
        {
            return !string.IsNullOrWhiteSpace(fanDisplayName)
                && fanDisplayName.IndexOf("GPU", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static bool IsCpuFan(string fanDisplayName)
        {
            return !string.IsNullOrWhiteSpace(fanDisplayName)
                && fanDisplayName.IndexOf("CPU", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static int TryReadGpuFromOpenHardware()
        {
            try
            {
                string hardwareDll = Path.Combine(FanControl.PluginsDirectory, "StagWare.Hardware.dll");

                if (!File.Exists(hardwareDll))
                {
                    return -1;
                }

                Assembly assembly = Assembly.LoadFrom(hardwareDll);
                Type monitorType = assembly.GetType("StagWare.Hardware.HardwareMonitor", false);

                if (monitorType == null)
                {
                    return -1;
                }

                object instance = monitorType.GetProperty("Instance", BindingFlags.Public | BindingFlags.Static)
                    ?.GetValue(null, null);

                if (instance == null)
                {
                    return -1;
                }

                object gpuTemps = monitorType.GetProperty("GpuTemperatures")
                    ?.GetValue(instance, null);

                if (!(gpuTemps is Array array) || array.Length == 0)
                {
                    return -1;
                }

                double max = 0;

                foreach (object entry in array)
                {
                    if (entry is KeyValuePair<string, double> pair && pair.Value > max)
                    {
                        max = pair.Value;
                    }
                }

                return max > 0 ? (int)Math.Round(max) : -1;
            }
            catch
            {
                return -1;
            }
        }
    }
}

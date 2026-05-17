using StagWare.FanControl.Configurations;
using StagWare.FanControl.Plugins;
using System;
using System.Collections.Generic;

namespace StagWare.FanControl
{
    internal class Fan
    {
        #region Constants

        public const int AutoFanSpeed = 101;
        private const int CriticalTemperatureOffset = 15;

        #endregion

        #region Private Fields

        private readonly bool readWriteWords;
        private readonly int criticalTemperature;
        private readonly IEmbeddedController ec;
        private readonly FanConfiguration fanConfig;

        private readonly int minSpeedValueWrite;
        private readonly int maxSpeedValueWrite;
        private readonly int minSpeedValueRead;
        private readonly int maxSpeedValueRead;
        private readonly int minSpeedValueReadAbs;
        private readonly int maxSpeedValueReadAbs;
        private readonly TemperatureThresholdManager threshMan;
        private readonly Dictionary<float, FanSpeedPercentageOverride> overriddenPercentages;
        private readonly Dictionary<int, FanSpeedPercentageOverride> overriddenValues;

        private float targetFanSpeed;

        #endregion

        #region Properties

        public float TargetSpeed
        {
            get
            {
                return this.CriticalModeEnabled
                    ? 100.0f
                    : this.targetFanSpeed;
            }
        }

        public float CurrentSpeed { get; private set; }
        public bool AutoControlEnabled { get; private set; }
        public bool CriticalModeEnabled { get; private set; }

        #endregion

        #region Constructors

        public Fan(IEmbeddedController ec, FanConfiguration config, int criticalTemperature, bool readWriteWords)
        {
            this.ec = ec;
            this.fanConfig = config;
            this.criticalTemperature = criticalTemperature;
            this.readWriteWords = readWriteWords;

            this.overriddenPercentages = new Dictionary<float, FanSpeedPercentageOverride>();
            this.overriddenValues = new Dictionary<int, FanSpeedPercentageOverride>();

            this.minSpeedValueWrite = config.MinSpeedValue;
            this.maxSpeedValueWrite = config.MaxSpeedValue;

            if (config.IndependentReadMinMaxValues)
            {
                this.minSpeedValueRead = config.MinSpeedValueRead;
                this.maxSpeedValueRead = config.MaxSpeedValueRead;
            }
            else
            {
                this.minSpeedValueRead = this.minSpeedValueWrite;
                this.maxSpeedValueRead = this.maxSpeedValueWrite;
            }

            this.minSpeedValueReadAbs = Math.Min(this.minSpeedValueRead, this.maxSpeedValueRead);
            this.maxSpeedValueReadAbs = Math.Max(this.minSpeedValueRead, this.maxSpeedValueRead);

            if (config.TemperatureThresholds != null
                && config.TemperatureThresholds.Count > 0)
            {
                this.threshMan = new TemperatureThresholdManager(config.TemperatureThresholds);
            }
            else
            {
                this.threshMan = new TemperatureThresholdManager(FanConfiguration.DefaultTemperatureThresholds);
            }

            foreach (FanSpeedPercentageOverride o in config.FanSpeedPercentageOverrides)
            {
                if (o.TargetOperation.HasFlag(OverrideTargetOperation.Write)
                    && !this.overriddenPercentages.ContainsKey(o.FanSpeedPercentage))
                {
                    this.overriddenPercentages.Add(o.FanSpeedPercentage, o);
                }

                if (o.TargetOperation.HasFlag(OverrideTargetOperation.Read)
                    && !this.overriddenValues.ContainsKey(o.FanSpeedValue))
                {
                    this.overriddenValues.Add(o.FanSpeedValue, o);
                }
            }
        }

        #endregion

        #region Public Methods

        public virtual void SetTargetSpeed(float speed, float temperature, bool readOnly)
        {
            UpdateTargetSpeed(speed, temperature);

            if (!readOnly)
            {
                ApplyTargetToEc();
            }
        }

        /// <summary>
        /// Updates target speed state without writing to the EC (used for ThinkPad dual-fan batch writes).
        /// </summary>
        internal void UpdateTargetSpeed(float speed, float temperature)
        {
            HandleCriticalMode(temperature);
            this.AutoControlEnabled = (speed < 0) || (speed > 100);

            if (AutoControlEnabled)
            {
                var threshold = this.threshMan.AutoSelectThreshold(temperature);

                if (threshold != null)
                {
                    this.targetFanSpeed = threshold.FanSpeed;
                }
            }
            else
            {
                this.targetFanSpeed = speed;
            }
        }

        internal void ApplyTargetToEc()
        {
            float speed = CriticalModeEnabled ? 100.0f : this.targetFanSpeed;
            ECWriteValue(PercentageToFanSpeed(speed));
        }

        internal int GetTargetEcSpeedValue()
        {
            float speed = CriticalModeEnabled ? 100.0f : this.targetFanSpeed;
            return PercentageToFanSpeed(speed);
        }

        internal int ReadEcSpeedRaw()
        {
            return ECReadValue();
        }

        internal bool IsBiosControlledEcValue(int ecValue)
        {
            return (ecValue & 0x80) != 0;
        }

        internal FanConfiguration FanConfig
        {
            get { return this.fanConfig; }
        }

        public virtual float GetCurrentSpeed()
        {
            if (this.fanConfig.FanSpeedRegister > 0 && this.fanConfig.FanSpeedMaxRpm > 0)
            {
                int rpm = ReadRpm();
                CurrentSpeed = Math.Min(100.0f, (rpm * 100.0f) / this.fanConfig.FanSpeedMaxRpm);
                return CurrentSpeed;
            }

            int speed = 0;

            // If the value is out of range 3 or more times,
            // minFanSpeed and/or maxFanSpeed are probably wrong.
            for (int i = 0; i <= 2; i++)
            {
                speed = ECReadValue();

                if ((speed >= minSpeedValueReadAbs) && (speed <= maxSpeedValueReadAbs))
                {
                    break;
                }
            }

            CurrentSpeed = FanSpeedToPercentage(speed);
            return CurrentSpeed;
        }

        internal int ReadEcTemperature()
        {
            return ThinkPadEcTemperature.Read(this.ec, this.fanConfig);
        }

        internal int ReadRpm()
        {
            if (this.fanConfig.FanSpeedRegister <= 0)
            {
                return 0;
            }

            SelectFanIfRequired();

            if (readWriteWords)
            {
                return this.ec.ReadWord((byte)this.fanConfig.FanSpeedRegister);
            }

            int lo = this.ec.ReadByte((byte)this.fanConfig.FanSpeedRegister);
            int hi = this.ec.ReadByte((byte)(this.fanConfig.FanSpeedRegister + 1));
            return lo | (hi << 8);
        }

        public virtual void Reset()
        {
            if (fanConfig.ResetRequired)
            {
                ECWriteValue(fanConfig.FanSpeedResetValue);
            }
        }

        #endregion

        #region Private Methods

        private int PercentageToFanSpeed(float percentage)
        {
            if ((percentage > 100) || (percentage < 0))
            {
                throw new ArgumentOutOfRangeException(
                    "percentage",
                    "Percentage must be greater or equal 0 and less or equal 100");
            }

            if (this.overriddenPercentages.ContainsKey(percentage))
            {
                return this.overriddenPercentages[percentage].FanSpeedValue;
            }
            else
            {
                return (int)Math.Round(minSpeedValueWrite
                    + (((maxSpeedValueWrite - minSpeedValueWrite) * percentage) / 100.0));
            }
        }

        private float FanSpeedToPercentage(int fanSpeed)
        {
            if (this.overriddenValues.ContainsKey(fanSpeed))
            {
                return this.overriddenValues[fanSpeed].FanSpeedPercentage;
            }
            else
            {
                if (minSpeedValueRead == maxSpeedValueRead)
                {
                    return 0;
                }
                else
                {
                    return ((float)(fanSpeed - minSpeedValueRead)
                        / (maxSpeedValueRead - minSpeedValueRead)) * 100;
                }
            }
        }

        private void ECWriteValue(int value)
        {
            SelectFanIfRequired();

            if (readWriteWords)
            {
                this.ec.WriteWord((byte)this.fanConfig.WriteRegister, (ushort)value);
            }
            else
            {
                this.ec.WriteByte((byte)this.fanConfig.WriteRegister, (byte)value);
            }
        }

        private int ECReadValue()
        {
            SelectFanIfRequired();

            return readWriteWords
                ? this.ec.ReadWord((byte)this.fanConfig.ReadRegister)
                : this.ec.ReadByte((byte)this.fanConfig.ReadRegister);
        }

        private void SelectFanIfRequired()
        {
            if (this.fanConfig.FanSwitchRegister != 0)
            {
                this.ec.WriteByte(
                    (byte)this.fanConfig.FanSwitchRegister,
                    (byte)this.fanConfig.FanSwitchValue);
            }
        }

        private void HandleCriticalMode(double temperature)
        {
            if (this.CriticalModeEnabled
                && (temperature < (this.criticalTemperature - CriticalTemperatureOffset)))
            {
                this.CriticalModeEnabled = false;
            }
            else if (temperature > this.criticalTemperature)
            {
                this.CriticalModeEnabled = true;
            }
        }

        #endregion
    }
}

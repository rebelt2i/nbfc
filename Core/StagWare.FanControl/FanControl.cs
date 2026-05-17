using NLog;
using StagWare.FanControl.Configurations;
using StagWare.FanControl.Plugins;
using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;

namespace StagWare.FanControl
{
    public class FanControl : IDisposable
    {
        #region Constants

#if DEBUG

        private const int MinPollInterval = 0;

#else

        private const int MinPollInterval = 100;

#endif

        public static int EcTimeout => 200;
        public static int MaxLockTimeout => 500;
        public static int DefaultPollInterval => 3000;
        public static string PluginsFolderDefaultName => "Plugins";
        public static int AutoFanSpeedPercentage => Fan.AutoFanSpeed;

        #endregion

        #region Private Fields

        private readonly object syncRoot = new object();
        private static readonly Logger logger = LogManager.GetCurrentClassLogger();

        private Timer timer;
        private readonly AsyncOperation asyncOp;

        private readonly int pollInterval;
        private readonly int lockTimeout;
        private readonly FanControlConfigV2 config;

        private readonly ITemperatureFilter tempFilter;
        private readonly ITemperatureMonitor tempMon;
        private readonly IEmbeddedController ec;
        private readonly Fan[] fans;

        private volatile bool readOnly;
        private volatile float temperature;
        private volatile FanInformation[] fanInfo;
        private readonly float[] requestedSpeeds;

        #endregion

        #region Constructor        

        public FanControl(FanControlConfigV2 config) : this(config, PluginsDirectory)
        {
        }

        public FanControl(FanControlConfigV2 config, string pluginsDirectory) : this(
            config,
            CreateTemperatureFilter(config),
            pluginsDirectory)
        {
        }

        public FanControl(FanControlConfigV2 config, ITemperatureFilter filter, string pluginsDirectory) : this(
            config,
            filter,
            LoadPlugin<IEmbeddedController>(pluginsDirectory, config.EcPluginId),
            LoadPlugin<ITemperatureMonitor>(pluginsDirectory, null))
        {
        }

        public FanControl(
            FanControlConfigV2 config,
            ITemperatureFilter filter,
            IEmbeddedController ec,
            ITemperatureMonitor tempMon)
        {
            if (config == null)
            {
                throw new ArgumentNullException(nameof(config));
            }

            if (filter == null)
            {
                throw new ArgumentNullException(nameof(filter));
            }

            if (ec == null)
            {
                throw new ArgumentNullException(nameof(ec));
            }

            if (tempMon == null)
            {
                throw new ArgumentNullException(nameof(tempMon));
            }

            this.ec = ec;
            this.tempMon = tempMon;
            this.tempFilter = filter;
            this.config = (FanControlConfigV2)config.Clone();
            this.pollInterval = config.EcPollInterval;

            if (config.UseThinkPadEcProtocol
                && config.FanWriteRetryInterval > 0
                && config.FanWriteRetryInterval < this.pollInterval)
            {
                this.pollInterval = Math.Max(MinPollInterval, config.FanWriteRetryInterval);
            }
            this.requestedSpeeds = new float[config.FanConfigurations.Count];
            this.fanInfo = new FanInformation[config.FanConfigurations.Count];
            this.fans = new Fan[config.FanConfigurations.Count];
            this.lockTimeout = Math.Min(MaxLockTimeout, config.EcPollInterval);
            this.asyncOp = AsyncOperationManager.CreateOperation(null);

            for (int i = 0; i < config.FanConfigurations.Count; i++)
            {
                var cfg = this.config.FanConfigurations[i];

                if (string.IsNullOrWhiteSpace(cfg.FanDisplayName))
                {
                    cfg.FanDisplayName = "Fan #" + (i + 1);
                }

                this.fanInfo[i] = new FanInformation(0, 0, true, false, cfg.FanDisplayName);
                this.fans[i] = new Fan(this.ec, cfg, config.CriticalTemperature, config.ReadWriteWords);
                this.requestedSpeeds[i] = AutoFanSpeedPercentage;
            }
        }

        internal FanControl(
            FanControlConfigV2 config,
            ITemperatureFilter filter,
            IEmbeddedController ec,
            ITemperatureMonitor tempMon,
            Fan[] fans) : this(config, filter, ec, tempMon)
        {
            if (fans == null)
            {
                throw new ArgumentNullException(nameof(fans));
            }

            if (fans.Length != this.fans.Length)
            {
                throw new ArgumentException(
                    "The length must be equal to the number of fan configurations",
                    nameof(fans));
            }

            this.fans = fans;
        }

        private static T LoadPlugin<T>(string pluginsDirectory, string preferredPluginId)
            where T : IFanControlPlugin
        {
            if (pluginsDirectory == null)
            {
                throw new ArgumentNullException(nameof(pluginsDirectory));
            }

            if (!Directory.Exists(pluginsDirectory))
            {
                throw new DirectoryNotFoundException(pluginsDirectory + " could not be found.");
            }

            var pluginLoader = new FanControlPluginLoader<T>(pluginsDirectory, preferredPluginId);

            if (pluginLoader.FanControlPlugin == null)
            {
                throw new PlatformNotSupportedException(
                    "Could not load a plugin which implements " + typeof(T)
                    + (string.IsNullOrWhiteSpace(preferredPluginId)
                        ? string.Empty
                        : " (requested: " + preferredPluginId + ")"));
            }

            return pluginLoader.FanControlPlugin;
        }

        private static ITemperatureFilter CreateTemperatureFilter(FanControlConfigV2 cfg)
        {
            int interval = Math.Max(cfg.EcPollInterval, MinPollInterval);
            return new ArithmeticMeanTemperatureFilter(interval);
        }

        #endregion

        #region Events

        public event EventHandler EcUpdated;

        #endregion

        #region Properties

        public static string PluginsDirectory
        {
            get
            {
                return Path.Combine(AssemblyDirectory, PluginsFolderDefaultName);
            }
        }

        public static string AssemblyDirectory
        {
            get
            {
                string codeBase = Assembly.GetExecutingAssembly().CodeBase;
                UriBuilder uri = new UriBuilder(codeBase);
                string path = Uri.UnescapeDataString(uri.Path);
                return Path.GetDirectoryName(path);
            }
        }

        public float Temperature
        {
            get { return this.temperature; }
        }

        public bool Enabled
        {
            get { return this.timer != null; }
        }

        public bool ReadOnly
        {
            get { return this.readOnly; }
        }

        public string TemperatureSourceDisplayName
        {
            get
            {
                if (this.tempMon == null || !this.tempMon.IsInitialized)
                {
                    return null;
                }
                else
                {
                    return this.tempMon.TemperatureSourceDisplayName;
                }
            }
        }

        public ReadOnlyCollection<FanInformation> FanInformation
        {
            get
            {
                return Array.AsReadOnly(fanInfo);
            }
        }

        #endregion

        #region Public Methods

        public void Start(bool readOnly = true)
        {
            if (this.disposed)
            {
                throw new ObjectDisposedException(nameof(FanControl));
            }

            if (this.Enabled)
            {
                if (this.readOnly != readOnly)
                {
                    if (readOnly)
                    {
                        ResetEc();
                    }
                    else
                    {
                        InitializeRegisterWriteConfigurations();
                    }

                    this.readOnly = readOnly;
                }
            }
            else
            {
                if (!this.tempMon.IsInitialized)
                {
                    this.tempMon.Initialize();

                    if (!this.tempMon.IsInitialized)
                    {
                        throw new PluginInitializationException(
                            "Could not initialize plugin of type " + nameof(ITemperatureMonitor));
                    }
                }

                if (!this.ec.IsInitialized)
                {
                    this.ec.Initialize();

                    if (!this.ec.IsInitialized)
                    {
                        throw new PluginInitializationException(
                            "Could not initialize plugin of type " + nameof(IEmbeddedController));
                    }
                }

                if (!readOnly)
                {
                    if (this.config.StopConflictingServices)
                    {
                        ConflictingServiceHelper.TryStopConflictingServices();
                    }
                    else
                    {
                        ConflictingServiceHelper.WarnIfConflictingServicesRunning();
                    }

                    InitializeRegisterWriteConfigurations();
                }

                this.readOnly = readOnly;

                if (this.timer == null)
                {
                    this.timer = new Timer(new TimerCallback(TimerCallback), null, 0, this.pollInterval);
                }
            }
        }

        public void SetTargetFanSpeed(float speed, int fanIndex)
        {
            if (fanIndex >= 0 && fanIndex < this.requestedSpeeds.Length)
            {
                Thread.VolatileWrite(ref this.requestedSpeeds[fanIndex], speed);

                // Reflect user target immediately for status/UI (EC apply may lag).
                this.fans[fanIndex].UpdateTargetSpeed(speed, GetFanTemperature(fanIndex));
                PublishFanTargetSpeed(fanIndex);

                if (this.Enabled)
                {
                    ThreadPool.QueueUserWorkItem(TimerCallback, null);
                }
            }
            else
            {
                throw new ArgumentOutOfRangeException("fanIndex");
            }
        }

        public void Stop()
        {
            if (this.disposed)
            {
                throw new ObjectDisposedException(nameof(FanControl));
            }
            else
            {
                StopFanControlCore();
            }
        }

        #endregion

        #region Protected Methods

        protected void OnEcUpdated()
        {
            EcUpdated?.Invoke(this, new EventArgs());
        }

        #endregion

        #region Private Methods

        #region Update EC

        private void TimerCallback(object state)
        {
            bool syncRootLockTaken = false;

            try
            {
                Monitor.TryEnter(syncRoot, lockTimeout, ref syncRootLockTaken);

                if (!syncRootLockTaken)
                {
                    return;
                }

                // We don't know which locks the plugins try to acquire internally,
                // therefore never try to access tempMon after calling ec.AcquireLock()
                double temp = this.tempMon.GetTemperature();
                this.temperature = (float)this.tempFilter.FilterTemperature(temp);

                if (this.ec.AcquireLock(EcTimeout))
                {
                    try
                    {
                        UpdateEc(this.temperature);
                    }
                    catch (Exception e)
                    {
                        logger.Error(e, "Could not update the EC");
                    }
                    finally
                    {
                        this.ec.ReleaseLock();
                    }

                    asyncOp.Post(args => OnEcUpdated(), null);
                }
            }
            finally
            {
                if (syncRootLockTaken)
                {
                    Monitor.Exit(syncRoot);
                }
            }
        }

        private void UpdateEc(float temperature)
        {
            // Re-init if current fan speeds are off by more than 15%
            bool reInitRequired = false;
            var speeds = new float[this.fans.Length];

            for (int i = 0; i < speeds.Length; i++)
            {
                speeds[i] = this.fans[i].GetCurrentSpeed();

                if (Math.Abs(speeds[i] - this.fans[i].TargetSpeed) > 15)
                {
                    reInitRequired = true;
                }
            }

            if (!readOnly)
            {
                ApplyRegisterWriteConfigurations(reInitRequired);
            }

            if (!readOnly && this.config.UseThinkPadEcProtocol)
            {
                ApplyThinkPadEcFanSpeeds(temperature);
            }
            else
            {
                ApplyStandardEcFanSpeeds(temperature, readOnly);
            }

            // Update fanInfo
            this.fanInfo = GetFanInformation();
        }

        private void ApplyStandardEcFanSpeeds(float temperature, bool readOnly)
        {
            int retryCount = Math.Max(1, this.config.FanWriteRetryCount);
            int retryDelayMs = this.config.FanWriteRetryInterval > 0
                ? this.config.FanWriteRetryInterval
                : 100;

            for (int i = 0; i < this.fans.Length; i++)
            {
                float speed = Thread.VolatileRead(ref this.requestedSpeeds[i]);
                this.fans[i].SetTargetSpeed(speed, GetFanTemperature(i), readOnly);

                if (!readOnly && retryCount > 1)
                {
                    for (int attempt = 1; attempt < retryCount; attempt++)
                    {
                        Thread.Sleep(retryDelayMs);
                        this.fans[i].GetCurrentSpeed();

                        if (Math.Abs(this.fans[i].CurrentSpeed - this.fans[i].TargetSpeed) <= 15)
                        {
                            break;
                        }

                        this.fans[i].SetTargetSpeed(speed, temperature, readOnly);
                    }
                }
            }
        }

        /// <summary>
        /// ThinkPad dual-fan protocol: write both fans in one sequence with verify/retry (TPFanCtrl2 SetFan).
        /// </summary>
        private void ApplyThinkPadEcFanSpeeds(float temperature)
        {
            const int delayBetweenFansMs = 50;
            const int delayBetweenAttemptsMs = 200;

            int retryCount = Math.Max(1, this.config.FanWriteRetryCount);
            int retryDelayMs = this.config.FanWriteRetryInterval > 0
                ? this.config.FanWriteRetryInterval
                : 100;

            for (int i = 0; i < this.fans.Length; i++)
            {
                float speed = Thread.VolatileRead(ref this.requestedSpeeds[i]);
                this.fans[i].UpdateTargetSpeed(speed, GetFanTemperature(i));
            }

            for (int attempt = 0; attempt < retryCount; attempt++)
            {
                for (int i = 0; i < this.fans.Length; i++)
                {
                    this.fans[i].ApplyTargetToEc();
                    Thread.Sleep(delayBetweenFansMs);
                }

                if (VerifyThinkPadEcFanSpeeds())
                {
                    return;
                }

                if (attempt + 1 < retryCount)
                {
                    Thread.Sleep(Math.Max(retryDelayMs, delayBetweenAttemptsMs));
                }
            }

            if (!VerifyThinkPadEcFanSpeeds())
            {
                int reg = this.fans.Length > 0
                    ? this.fans[0].FanConfig.WriteRegister
                    : 0x2F;
                int sample = this.fans.Length > 0 ? this.fans[0].ReadEcSpeedRaw() : -1;

                logger.Warn(
                    "ThinkPad EC fan control still in BIOS mode or not applied (register {0} read 0x{1:X2}, expected manual level). "
                    + "Stop Lenovo thermal services and verify Phase 0 write test.",
                    reg,
                    sample);
            }
        }

        private bool VerifyThinkPadEcFanSpeeds()
        {
            for (int i = 0; i < this.fans.Length; i++)
            {
                int expected = this.fans[i].GetTargetEcSpeedValue();
                int actual = this.fans[i].ReadEcSpeedRaw();

                if (this.fans[i].IsBiosControlledEcValue(actual))
                {
                    return false;
                }

                if ((actual & 0x7F) != (expected & 0x7F))
                {
                    return false;
                }
            }

            return true;
        }

        private FanInformation[] GetFanInformation()
        {
            var info = new FanInformation[this.fans.Length];

            for (int i = 0; i < this.fans.Length; i++)
            {
                this.fans[i].GetCurrentSpeed();

                float targetSpeed = GetDisplayedTargetSpeed(i);

                int temp = this.fans[i].ReadEcTemperature();
                int rpm = this.fans[i].ReadRpm();

                info[i] = new FanInformation(
                    targetSpeed,
                    this.fans[i].CurrentSpeed,
                    this.fans[i].AutoControlEnabled,
                    this.fans[i].CriticalModeEnabled,
                    this.config.FanConfigurations[i].FanDisplayName,
                    temp,
                    rpm);
            }

            return info;
        }

        private float GetFanTemperature(int fanIndex)
        {
            int ecTemp = this.fans[fanIndex].ReadEcTemperature();

            if (ecTemp >= 0)
            {
                return ecTemp;
            }

            return this.temperature;
        }

        private float GetDisplayedTargetSpeed(int fanIndex)
        {
            float requested = Thread.VolatileRead(ref this.requestedSpeeds[fanIndex]);

            if (requested >= 0 && requested <= 100)
            {
                return requested;
            }

            return this.fans[fanIndex].TargetSpeed;
        }

        private void PublishFanTargetSpeed(int fanIndex)
        {
            if (this.fanInfo == null || fanIndex < 0 || fanIndex >= this.fanInfo.Length)
            {
                return;
            }

            float targetSpeed = GetDisplayedTargetSpeed(fanIndex);
            var current = this.fanInfo[fanIndex];

            this.fanInfo[fanIndex] = new FanInformation(
                targetSpeed,
                current.CurrentFanSpeed,
                current.AutoFanControlEnabled,
                current.CriticalModeEnabled,
                current.FanDisplayName,
                current.Temperature,
                current.Rpm);
        }

        private void StopFanControlCore()
        {
            if (this.Enabled)
            {
                if (timer != null)
                {
                    // Wait until all callbacks have completed and then dispose the timer
                    using (var handle = new EventWaitHandle(false, EventResetMode.ManualReset))
                    {
                        timer.Dispose(handle);

                        if (handle.WaitOne())
                        {
                            timer = null;
                        }
                    }
                }

                if (!readOnly)
                {
                    ResetEc(true);
                }
            }
        }

        private void InitializeRegisterWriteConfigurations()
        {
            bool syncRootLockTaken = false;

            try
            {
                Monitor.TryEnter(syncRoot, lockTimeout, ref syncRootLockTaken);

                if (!syncRootLockTaken)
                {
                    throw new TimeoutException("EC initialization failed: Could not enter monitor");
                }

                if (!this.ec.AcquireLock(EcTimeout))
                {
                    throw new TimeoutException("EC initialization failed: Could not acquire EC lock");
                }

                try
                {
                    ApplyRegisterWriteConfigurations(true);
                }
                finally
                {
                    this.ec.ReleaseLock();
                }
            }
            finally
            {
                if (syncRootLockTaken)
                {
                    Monitor.Exit(syncRoot);
                }
            }
        }

        private void ApplyRegisterWriteConfigurations(bool initializing = false)
        {
            if (this.config.RegisterWriteConfigurations != null)
            {
                foreach (RegisterWriteConfiguration cfg in this.config.RegisterWriteConfigurations)
                {
                    if (initializing || cfg.WriteOccasion == RegisterWriteOccasion.OnWriteFanSpeed)
                    {
                        ApplyRegisterWriteConfig((byte)cfg.Value, (byte)cfg.Register, cfg.WriteMode);
                    }
                }
            }
        }

        private void ApplyRegisterWriteConfig(byte value, byte register, RegisterWriteMode mode)
        {
            if (mode == RegisterWriteMode.And)
            {
                value &= this.ec.ReadByte(register);
            }
            else if (mode == RegisterWriteMode.Or)
            {
                value |= this.ec.ReadByte(register);
            }

            this.ec.WriteByte(register, value);
        }

        #endregion

        #region Reset EC

        private void ResetEc(bool force = false)
        {
            if (!this.config.RegisterWriteConfigurations.Any(x => x.ResetRequired)
                && !this.config.FanConfigurations.Any(x => x.ResetRequired))
            {
                return;
            }

            bool syncRootLockTaken = false;

            try
            {
                Monitor.TryEnter(syncRoot, MaxLockTimeout * 2, ref syncRootLockTaken);

                if (!syncRootLockTaken && !force)
                {
                    throw new TimeoutException("EC reset failed: Could not enter monitor");
                }

                bool ecLockAcquired = this.ec.AcquireLock(EcTimeout * 2);

                if (!ecLockAcquired && !force)
                {
                    throw new TimeoutException("EC reset failed: Could not acquire EC lock");
                }

                // If force is true, try to reset the EC even if AquireLock failed
                try
                {
                    int tries = force ? 3 : 1;

                    for (int i = 0; i < tries; i++)
                    {
                        ResetRegisterWriteConfigs();
                        ResetFans();
                    }
                }
                catch (Exception e)
                {
                    logger.Error(e, "EC reset failed");
                }
                finally
                {
                    if (ecLockAcquired)
                    {
                        this.ec.ReleaseLock();
                    }
                }
            }
            finally
            {
                if (syncRootLockTaken)
                {
                    Monitor.Exit(syncRoot);
                }
            }
        }

        private void ResetFans()
        {
            foreach (Fan fan in this.fans)
            {
                fan.Reset();
            }
        }

        private void ResetRegisterWriteConfigs()
        {
            foreach (RegisterWriteConfiguration cfg in this.config.RegisterWriteConfigurations)
            {
                if (cfg.ResetRequired)
                {
                    ApplyRegisterWriteConfig((byte)cfg.ResetValue, (byte)cfg.Register, cfg.ResetWriteMode);
                }
            }
        }

        #endregion

        #endregion

        #region IDisposable implementation

        private bool disposed = false;

        public void Dispose()
        {
            if (!this.disposed)
            {
                this.disposed = true;
                StopFanControlCore();

                if (this.asyncOp != null)
                {
                    this.asyncOp.OperationCompleted();
                }

                if (this.ec != null)
                {
                    this.ec.Dispose();
                }

                if (this.tempMon != null)
                {
                    this.tempMon.Dispose();
                }

                GC.SuppressFinalize(this);
            }
        }

        #endregion
    }
}

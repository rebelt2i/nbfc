using GalaSoft.MvvmLight;
using GalaSoft.MvvmLight.Messaging;
using NbfcClient.Messages;
using NbfcClient.NbfcService;
using NbfcClient.Services;
using System;

namespace NbfcClient.ViewModels
{
    public class FanControllerViewModel : ViewModelBase
    {
        #region Private Fields

        private float currentFanSpeed;
        private float targetFanSpeed;
        private float currentFanSpeedLevel;
        private int fanSpeedSteps;
        private bool isAutoFanControlEnabled;
        private string fanDisplayName;
        private bool isCriticalModeEnabled;

        private IFanControlClient client;
        private int fanIndex;
        private int sliderDragCount;
        private DateTime suppressSliderSyncUntilUtc;

        #endregion

        #region Constructors

        public FanControllerViewModel(IFanControlClient client, int fanIndex)
        {
            this.fanIndex = fanIndex;
            this.client = client;
            this.client.FanControlStatusChanged += Client_FanControlStatusChanged;
            Messenger.Default.Register<ReloadFanControlInfoMessage>(this, Refresh);

            Refresh(true);
        }

        #endregion

        #region Properties

        public float CurrentFanSpeedLevel
        {
            get { return this.currentFanSpeedLevel; }
            set
            {
                if (Set(ref this.currentFanSpeedLevel, value))
                {
                    suppressSliderSyncUntilUtc = DateTime.UtcNow.AddSeconds(2);
                    client.SetTargetFanSpeed(GetFanSpeedPercentage(value), fanIndex);
                }
            }
        }

        public int FanIndex
        {
            get { return this.fanIndex; }
            private set { this.Set(ref this.fanIndex, value); }
        }

        public string FanDisplayName
        {
            get { return this.fanDisplayName; }
            private set { this.Set(ref this.fanDisplayName, value); }
        }

        public float TargetFanSpeed
        {
            get { return this.targetFanSpeed; }
            private set { this.Set(ref this.targetFanSpeed, value); }
        }

        public float CurrentFanSpeed
        {
            get { return this.currentFanSpeed; }
            private set { this.Set(ref this.currentFanSpeed, value); }
        }

        public bool IsAutoFanControlEnabled
        {
            get { return this.isAutoFanControlEnabled; }
            private set { this.Set(ref this.isAutoFanControlEnabled, value); }
        }

        public bool IsCriticalModeEnabled
        {
            get { return this.isCriticalModeEnabled; }
            private set { this.Set(ref this.isCriticalModeEnabled, value); }
        }

        public int FanSpeedSteps
        {
            get { return this.fanSpeedSteps; }
            private set { this.Set(ref this.fanSpeedSteps, value); }
        }

        #endregion

        #region Public Methods

        public void NotifySliderDragStarted()
        {
            this.sliderDragCount++;
        }

        public void NotifySliderDragCompleted()
        {
            if (this.sliderDragCount > 0)
            {
                this.sliderDragCount--;
            }

            this.suppressSliderSyncUntilUtc = DateTime.UtcNow.AddSeconds(1);
        }

        #endregion

        #region Private Methods

        private void Refresh(ReloadFanControlInfoMessage msg)
        {
            Refresh(msg.IgnoreCache);
        }

        private void Refresh(bool ignoreCache)
        {
            FanControlInfo info = ignoreCache
                ? client.GetFanControlInfo()
                : client.FanControlInfo;

            UpdateProperties(info);
        }

        private void UpdateProperties(FanControlInfo info)
        {
            FanStatus status = null;

            if ((info.FanStatus == null) || (info.FanStatus.Length <= fanIndex))
            {
                status = new FanStatus();
            }
            else
            {
                status = info.FanStatus[fanIndex];
            }

            Set(ref currentFanSpeed, status.CurrentFanSpeed, nameof(CurrentFanSpeed));
            Set(ref targetFanSpeed, status.TargetFanSpeed, nameof(TargetFanSpeed));
            Set(ref fanDisplayName, status.FanDisplayName, nameof(FanDisplayName));
            Set(ref fanSpeedSteps, status.FanSpeedSteps, nameof(FanSpeedSteps));
            Set(ref isAutoFanControlEnabled, status.AutoControlEnabled, nameof(IsAutoFanControlEnabled));
            Set(ref isCriticalModeEnabled, status.CriticalModeEnabled, nameof(IsCriticalModeEnabled));

            if (ShouldSkipSliderSync(status))
            {
                return;
            }

            if (status.AutoControlEnabled)
            {
                // set the current speed level to (highest possible value) + 1 to indicate autmatic control
                Set(ref currentFanSpeedLevel, status.FanSpeedSteps + 1, nameof(CurrentFanSpeedLevel));
            }
            else
            {
                int level = (int)Math.Round((status.TargetFanSpeed / 100.0) * status.FanSpeedSteps);
                Set(ref currentFanSpeedLevel, level, nameof(CurrentFanSpeedLevel));
            }
        }

        private bool ShouldSkipSliderSync(FanStatus status)
        {
            if (status.AutoControlEnabled)
            {
                return false;
            }

            if (this.sliderDragCount > 0)
            {
                return true;
            }

            if (DateTime.UtcNow < this.suppressSliderSyncUntilUtc)
            {
                return true;
            }

            return false;
        }

        private float GetFanSpeedPercentage(float sliderValue)
        {
            if (this.fanSpeedSteps == 0)
            {
                return 0;
            }
            else
            {
                return (sliderValue / this.fanSpeedSteps) * 100.0f;
            }
        }

        #endregion

        #region EventHandlers

        private void Client_FanControlStatusChanged(object sender, FanControlStatusChangedEventArgs e)
        {
            Refresh(false);
        }

        #endregion
    }
}

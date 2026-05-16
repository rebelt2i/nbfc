using NLog;
using System;
using System.ServiceProcess;

namespace StagWare.FanControl
{
    internal static class ConflictingServiceHelper
    {
        private static readonly Logger logger = LogManager.GetCurrentClassLogger();

        private static readonly string[] ConflictingServiceNames =
        {
            "LenovoFanTableService",
            "IBMPMSVC",
            "Lenovo Intelligent Cooling",
            "LenovoICM",
            "LenovoVantageService",
            "Lenovo Instant On"
        };

        public static void WarnIfConflictingServicesRunning()
        {
            foreach (string name in ConflictingServiceNames)
            {
                if (IsServiceRunning(name))
                {
                    logger.Warn(
                        "Conflicting service '{0}' is running. Fan control may not work. "
                        + "Consider stopping it or set StopConflictingServices in the config.",
                        name);
                }
            }
        }

        public static void TryStopConflictingServices()
        {
            foreach (string name in ConflictingServiceNames)
            {
                try
                {
                    using (var sc = new ServiceController(name))
                    {
                        if (sc.Status == ServiceControllerStatus.Running)
                        {
                            logger.Info("Stopping conflicting service '{0}'", name);
                            sc.Stop();
                            sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(30));
                        }
                    }
                }
                catch (InvalidOperationException)
                {
                }
                catch (Exception e)
                {
                    logger.Warn(e, "Could not stop service '{0}'", name);
                }
            }
        }

        private static bool IsServiceRunning(string name)
        {
            try
            {
                using (var sc = new ServiceController(name))
                {
                    return sc.Status == ServiceControllerStatus.Running;
                }
            }
            catch (InvalidOperationException)
            {
                return false;
            }
        }
    }
}

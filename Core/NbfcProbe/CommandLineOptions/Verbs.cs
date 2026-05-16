using clipr;

namespace NbfcProbe.CommandLineOptions
{
    [ApplicationInfo(Name = "ec-probe.exe", Description = "NoteBook FanControl EC probing tool")]
    public class Verbs
    {
        [NamedArgument(
            'p',
            "plugin",
            Action = ParseAction.Store,
            Constraint = NumArgsConstraint.Exactly,
            NumArgs = 1,
            MetaVar = "id",
            Description = "EC plugin id (e.g. StagWare.Plugins.ECThinkPad). Default: auto-select by priority.")]
        public string EcPluginId { get; set; }

        [Verb("dump", "Dump all EC registers")]
        public ECDumpVerb ECDump { get; set; }

        [Verb("read", "Read a byte from a EC register")]
        public ECReadVerb ECRead { get; set; }

        [Verb("write", "Write a byte to a EC register")]
        public ECWriteVerb ECWrite { get; set; }

        [Verb("monitor", "Monitor all EC registers for changes")]
        public ECMonitorVerb ECMonitor { get; set; }
    }
}

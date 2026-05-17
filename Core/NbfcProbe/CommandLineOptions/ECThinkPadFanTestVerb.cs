using clipr;

namespace NbfcProbe.CommandLineOptions
{
    public class ECThinkPadFanTestVerb
    {
        [NamedArgument(
            'l',
            "level",
            Action = ParseAction.Store,
            Constraint = NumArgsConstraint.Exactly,
            NumArgs = 1,
            Description = "Manual fan level to write (0-7, default: 3)")]
        public byte Level { get; set; }

        [NamedArgument(
            "mux-fan1",
            Action = ParseAction.Store,
            Constraint = NumArgsConstraint.Exactly,
            NumArgs = 1,
            Description = "Fan 1 mux value for register 0x31 (default: 0x40)")]
        public byte MuxFan1 { get; set; }

        [NamedArgument(
            "mux-fan2",
            Action = ParseAction.Store,
            Constraint = NumArgsConstraint.Exactly,
            NumArgs = 1,
            Description = "Fan 2 mux value for register 0x31 (default: 0x41)")]
        public byte MuxFan2 { get; set; }

        [NamedArgument(
            "fan-control",
            Action = ParseAction.Store,
            Constraint = NumArgsConstraint.Exactly,
            NumArgs = 1,
            Description = "Fan control register (default: 0x2F)")]
        public byte FanControlRegister { get; set; }

        [NamedArgument(
            "fan-switch",
            Action = ParseAction.Store,
            Constraint = NumArgsConstraint.Exactly,
            NumArgs = 1,
            Description = "Fan switch register (default: 0x31)")]
        public byte FanSwitchRegister { get; set; }
    }
}

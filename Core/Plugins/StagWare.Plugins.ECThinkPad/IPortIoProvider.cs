namespace StagWare.Plugins
{
    internal interface IPortIoProvider
    {
        void WritePort(int port, byte value);

        byte ReadPort(int port);
    }
}

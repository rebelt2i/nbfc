using NbfcClient.ViewModels;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;

namespace NbfcClient.UserControls
{
    public partial class FanController : UserControl
    {
        public FanController()
        {
            InitializeComponent();
            Loaded += FanController_Loaded;
        }

        private void FanController_Loaded(object sender, System.Windows.RoutedEventArgs e)
        {
            var vm = DataContext as FanControllerViewModel;
            if (vm == null)
            {
                return;
            }

            FanSpeedSlider.AddHandler(
                Thumb.DragStartedEvent,
                new DragStartedEventHandler((s, args) => vm.NotifySliderDragStarted()),
                true);

            FanSpeedSlider.AddHandler(
                Thumb.DragCompletedEvent,
                new DragCompletedEventHandler((s, args) => vm.NotifySliderDragCompleted()),
                true);
        }
    }
}

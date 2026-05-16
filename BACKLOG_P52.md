# Backlog: ThinkPad P52 Lüftersteuerung in NBFC

## Problemstellung

NBFC schreibt Lüfterwerte direkt in ein einzelnes EC-Register (`WriteByte(register, value)`).
Auf dem ThinkPad P52 (und verwandten Workstation-Modellen ab ~2018) scheitert das aus drei Gründen:

1. **Dual-Fan-Multiplexing**: Der EC hat zwei Lüfter hinter einem gemeinsamen Steuerregister (`0x2F`).
   Vor jedem Schreiben muss über Register `0x31` ausgewählt werden, welcher Lüfter angesprochen wird.
2. **BIOS-Override**: Der EC erzwingt `0x80` (BIOS-Kontrolle) im Steuerregister, wenn kein
   korrektes Umschaltprotokoll eingehalten wird.
3. **Lenovo Intelligent Cooling**: Ein Windows-Dienst schreibt im Millisekundentakt `0x80` zurück
   und blockiert damit jede externe Steuerung.

TPFanCtrl2 (Public Domain / Unlicense) löst alle drei Probleme. Die Logik muss als
NBFC-Plugin portiert werden.

---

## Referenz-Quellen

| Quelle | Relevante Dateien / Stellen |
|---|---|
| TPFanCtrl2 (Shuzhengz/FanDjango) | `fancontrol/fanstuff.cpp` (SetFan, ReadEcRaw), `fancontrol/portio.cpp` (EC I/O), `fancontrol/winstuff.cpp` (MUTEXSEM), `fancontrol/fancontrol.h` (FCSTATE) |
| NBFC (hirschmann) | `Core/Plugins/StagWare.Plugins.ECWindows/ECWindows.cs`, `Core/StagWare.Hardware.LPC/EmbeddedControllerBase.cs`, `Core/StagWare.FanControl/Fan.cs`, `Core/StagWare.FanControl/FanControl.cs`, `Core/StagWare.Configurations/*` |

---

## Phase 0: Hardware-Vorbereitung & EC-Register-Map

> Ziel: Die tatsächlichen Register-Adressen des P52-EC kennen, bevor Code geschrieben wird.

### Schritt 0.1 — Lenovo-Dienste deaktivieren

Auf dem P52 müssen vor jeder Arbeit folgende Dienste gestoppt werden, da sie permanent
in den EC schreiben und Messergebnisse verfälschen:

```
sc stop "LenovoFanTableService"
sc config "LenovoFanTableService" start=disabled

sc stop "IBMPMSVC"
sc config "IBMPMSVC" start=disabled

sc stop "Lenovo Intelligent Cooling"
sc config "Lenovo Intelligent Cooling" start=disabled
```

Prüfen, ob nach Neustart kein Lenovo-Dienst mehr auf EC-Ports zugreift.
Ggf. im Task-Manager / Sysinternals Process Monitor nach Zugriffen auf `\Device\WinRing0` filtern.

### Schritt 0.2 — EC-Register mit nbfc-probe kartieren

NBFC enthält `NbfcProbe` (`Core/NbfcProbe/`). Damit die vollständige EC-Register-Map lesen:

```
NbfcProbe.exe ec-monitor
```

Folgende Register dokumentieren (Vergleich mit TPFanCtrl2-Defaults):

| Register | TPFanCtrl2-Name | Erwartete Adresse | Beschreibung |
|---|---|---|---|
| Fan Control | `TP_ECOFFSET_FAN` | `0x2F` | Lüfterstufe lesen/schreiben |
| Fan Switch | `TP_ECOFFSET_FAN_SWITCH` | `0x31` | Lüfter 1/2 auswählen |
| Fan Speed | `TP_ECOFFSET_FANSPEED` | `0x84` | RPM (16-bit, lo/hi) |
| Temp Sensors 0-7 | `TP_ECOFFSET_TEMP0` | `0x78`-`0x7F` | Temperatursensoren Block 1 |
| Temp Sensors 8-11 | `TP_ECOFFSET_TEMP1` | `0xC0`-`0xC3` | Temperatursensoren Block 2 |
| Fan1 Select Value | `TP_ECVALUE_SELFAN1` | Unklar (P50: `0x40`) | Wert für 0x31 → Fan 1 |
| Fan2 Select Value | `TP_ECVALUE_SELFAN2` | Unklar (P50: `0x41`) | Wert für 0x31 → Fan 2 |

**Achtung**: Das P50 nutzt möglicherweise andere Select-Values als das P52. Beide Register
müssen am echten Gerät verifiziert werden (EC-Monitor: 0x31 beobachten, während BIOS
zwischen Lüftern wechselt).

### Schritt 0.3 — EC-Port-Typ bestimmen

TPFanCtrl2 unterstützt zwei EC-Port-Konfigurationen:

- **Type 1** (neuere Modelle): Ctrl `0x1604`, Data `0x1600`
- **Type 2** (ältere Modelle): Ctrl `0x66`, Data `0x62`

NBFC nutzt aktuell immer Type 2 (`EmbeddedControllerBase.cs`: `CommandPort = 0x66`,
`DataPort = 0x62`). Beim P52 muss geprüft werden, ob Type 1 nötig ist.
TPFanCtrl2 probiert Type 1 zuerst und fällt auf Type 2 zurück (siehe `portio.cpp` Z. 71-82).

---

## Phase 1: Neues EC-Plugin `StagWare.Plugins.ECThinkPad`

> Ziel: Ein MEF-Plugin das den ThinkPad-spezifischen EC-Zugriff kapselt.

### Schritt 1.1 — Projektstruktur anlegen

Neues Projekt erstellen, analog zu `StagWare.Plugins.ECWindows`:

```
Core/Plugins/StagWare.Plugins.ECThinkPad/
├── ECThinkPad.cs                    # Hauptklasse
├── ThinkPadEcPortIo.cs              # Port-I/O mit Type1/Type2-Fallback
├── Properties/
│   └── AssemblyInfo.cs
└── StagWare.Plugins.ECThinkPad.csproj
```

csproj als Kopie von `StagWare.Plugins.ECWindows.csproj` mit:
- AssemblyName: `StagWare.Plugins.ECThinkPad`
- Gleiche ProjectReferences (StagWare.FanControl, StagWare.Hardware.LPC, StagWare.Hardware)

### Schritt 1.2 — `ThinkPadEcPortIo.cs` implementieren

Port-I/O-Klasse mit Type1/Type2-Fallback, portiert aus TPFanCtrl2 `portio.cpp`:

```csharp
// Kernlogik (Pseudocode, vollständig implementieren):
internal class ThinkPadEcPortIo
{
    // Type 1 Ports (neuere ThinkPads, z.B. P52)
    private const int TYPE1_CTRL = 0x1604;
    private const int TYPE1_DATA = 0x1600;

    // Type 2 Ports (Standard ACPI)
    private const int TYPE2_CTRL = 0x66;
    private const int TYPE2_DATA = 0x62;

    // EC Status Flags
    private const byte FLAG_OBF = 0x01;
    private const byte FLAG_IBF = 0x02;

    // EC Commands
    private const byte CMD_READ  = 0x80;
    private const byte CMD_WRITE = 0x81;

    private int ctrlPort;
    private int dataPort;

    // Port-Typ erkennen: Type 1 probieren, bei Fehler Type 2
    public bool Initialize(IPortIoProvider portIo) { ... }

    // Byte lesen mit Timeout und Retry (aus portio.cpp ReadByteFromEC)
    public bool ReadByte(byte offset, out byte value) { ... }

    // Byte schreiben mit Timeout und Retry (aus portio.cpp WriteByteToEC)
    public bool WriteByte(byte offset, byte value) { ... }

    // Flags warten (aus portio.cpp WaitForFlags)
    private bool WaitForFlags(byte flags, bool set, int timeout) { ... }
}
```

Unterschiede zu `EmbeddedControllerBase.cs`:
- Die bestehende Basisklasse hat hardcodierte Ports (`0x66`/`0x62`).
  Das neue Plugin muss die Ports dynamisch wählen.
- TPFanCtrl2 wartet auf `!(IBF | OBF)` als Idle-Zustand, während
  `EmbeddedControllerBase` auf einzelne Flags prüft. Beides portieren
  und am Gerät testen, welches Verfahren zuverlässiger ist.

### Schritt 1.3 — `ECThinkPad.cs` implementieren

```csharp
[Export(typeof(IEmbeddedController))]
[FanControlPluginMetadata(
    "StagWare.Plugins.ECThinkPad",
    SupportedPlatforms.Windows,
    SupportedCpuArchitectures.x86 | SupportedCpuArchitectures.x64,
    Priority = 5,           // niedriger als ECWindows (10) = nur geladen wenn konfiguriert
    MinOSVersion = "6.1")]  // Windows 7+
public class ECThinkPad : IEmbeddedController
{
    private HardwareMonitor hwMon;
    private ThinkPadEcPortIo portIo;
    private Mutex ecMutex;              // "Access_Thinkpad_EC"

    private const string EC_MUTEX_NAME = "Access_Thinkpad_EC";

    public bool IsInitialized { get; private set; }

    public void Initialize()
    {
        this.hwMon = HardwareMonitor.Instance;
        this.portIo = new ThinkPadEcPortIo();

        // ThinkPad-EC-Mutex erstellen (gleicher Name wie TPFanCtrl2)
        this.ecMutex = new Mutex(false, EC_MUTEX_NAME);

        this.IsInitialized = this.hwMon != null
            && this.portIo.Initialize(/* IPortIoProvider von hwMon */);
    }

    public bool AcquireLock(int timeout)
    {
        // Zuerst ISA-Bus-Mutex (wie ECWindows), dann ThinkPad-Mutex
        if (!this.hwMon.WaitIsaBusMutex(timeout)) return false;

        try
        {
            return this.ecMutex.WaitOne(timeout);
        }
        catch (AbandonedMutexException)
        {
            return true;  // Mutex von abgestürztem Prozess übernommen
        }
    }

    public void ReleaseLock()
    {
        try { this.ecMutex.ReleaseMutex(); } catch { }
        this.hwMon.ReleaseIsaBusMutex();
    }

    // ReadByte/WriteByte/ReadWord/WriteWord delegieren an this.portIo
    // mit internem Retry (max 5 Versuche, wie EmbeddedControllerBase)
    public byte ReadByte(byte register) { ... }
    public void WriteByte(byte register, byte value) { ... }
    public ushort ReadWord(byte register) { ... }
    public void WriteWord(byte register, ushort value) { ... }

    public void Dispose()
    {
        this.ecMutex?.Dispose();
        // ISA-Mutex freigeben
    }
}
```

**Wichtig**: Die `Priority` muss **niedriger** sein als die von ECWindows (10), damit
das Plugin nicht automatisch bei Nicht-ThinkPads geladen wird. Alternativ: Plugin nur
laden wenn die XML-Config ein ThinkPad-spezifisches Flag enthält (siehe Phase 2).

### Schritt 1.4 — Plugin-Auswahl erweitern

Aktuell wählt `FanControlPluginLoader<T>` das Plugin mit der **höchsten Priority**,
das kompatibel ist. Es gibt keine Möglichkeit, per Config ein bestimmtes Plugin zu wählen.

Optionen (eine wählen):

**Option A (minimal)**: ECThinkPad bekommt `Priority = 15` (höher als ECWindows = 10).
In `ECThinkPad.Initialize()` prüfen, ob der Type-1-Port antwortet. Wenn nicht,
`IsInitialized = false` setzen → Loader fällt auf ECWindows zurück.
- Vorteil: Keine Änderungen am Loader oder Config-Modell nötig.
- Nachteil: Auf jedem Nicht-ThinkPad wird ein Init-Versuch gemacht und fällt durch.

**Option B (sauber)**: Neues Feld `EcPluginId` in `FanControlConfigV2` ergänzen.
Wenn gesetzt, lädt `FanControlPluginLoader` gezielt dieses Plugin statt nach Priority.
- Vorteil: Explizite Steuerung, kein Raten.
- Nachteil: Änderung am Config-Modell und am Loader.

**Empfehlung**: Option A für den ersten Wurf, Option B als Follow-up.

---

## Phase 2: Konfigurationsmodell erweitern

> Ziel: Die XML-Config kann ThinkPad-spezifische Parameter beschreiben.

### Schritt 2.1 — `FanConfiguration.cs` erweitern

Neue Properties in `Core/StagWare.Configurations/FanConfiguration.cs`:

```csharp
// ThinkPad-Dual-Fan: Register das vor dem Lesen/Schreiben den Lüfter auswählt
public int FanSwitchRegister { get; set; }     // z.B. 0x31

// Wert der in FanSwitchRegister geschrieben wird um DIESEN Lüfter auszuwählen
public int FanSwitchValue { get; set; }        // z.B. 0x40 für Fan1, 0x41 für Fan2

// Register für RPM-Auslese (16-bit lo/hi, optional)
public int FanSpeedRegister { get; set; }      // z.B. 0x84
```

Diese in `Clone()` mit kopieren. Defaults auf `0` (= Feature nicht aktiv, Fallback
auf bestehendes Verhalten).

### Schritt 2.2 — `FanControlConfigV2.cs` erweitern

Neue Properties in `Core/StagWare.Configurations/FanControlConfigV2.cs`:

```csharp
// Erweiterte EC-Zugriffssteuerung
public bool UseThinkPadEcProtocol { get; set; }   // aktiviert Fan-Switch-Sequenz

// Aggressives Re-Apply: Intervall in ms wie oft der gewünschte Wert
// nachgeschrieben wird, um BIOS-Override zu überschreiben.
// 0 = nur bei normalem Poll. Empfehlung P52: 500ms.
public int FanWriteRetryInterval { get; set; }

// Maximale Versuche für Write+Verify pro Zyklus
public int FanWriteRetryCount { get; set; }        // Default: 5 (wie TPFanCtrl2)
```

Diese in `Clone()` mit kopieren. `UseThinkPadEcProtocol` Default `false`,
`FanWriteRetryCount` Default `1` (bestehendes Verhalten).

### Schritt 2.3 — XML-Serialisierung verifizieren

Die Config-Klassen verwenden `XmlSerializer`. Neue Properties werden automatisch
serialisiert. Testen, dass alte Configs ohne die neuen Felder weiterhin laden
(Defaults greifen für fehlende Elemente).

---

## Phase 3: Kern-Logik anpassen (`Fan.cs`, `FanControl.cs`)

> Ziel: Fan-Schreibvorgänge nutzen das ThinkPad-Protokoll wenn konfiguriert.

### Schritt 3.1 — `Fan.cs` → `ECWriteValue` erweitern

Aktuelle Implementierung (`Fan.cs` Z. 214-224):

```csharp
private void ECWriteValue(int value)
{
    if (readWriteWords)
        this.ec.WriteWord((byte)this.fanConfig.WriteRegister, (ushort)value);
    else
        this.ec.WriteByte((byte)this.fanConfig.WriteRegister, (byte)value);
}
```

Neue Implementierung:

```csharp
private void ECWriteValue(int value)
{
    // ThinkPad: Erst Fan-Switch-Register schreiben, dann Wert
    if (this.fanConfig.FanSwitchRegister != 0)
    {
        this.ec.WriteByte(
            (byte)this.fanConfig.FanSwitchRegister,
            (byte)this.fanConfig.FanSwitchValue);
    }

    if (readWriteWords)
        this.ec.WriteWord((byte)this.fanConfig.WriteRegister, (ushort)value);
    else
        this.ec.WriteByte((byte)this.fanConfig.WriteRegister, (byte)value);
}
```

Gleiche Änderung in `ECReadValue` für korrekte Zuordnung beim Lesen:

```csharp
private int ECReadValue()
{
    if (this.fanConfig.FanSwitchRegister != 0)
    {
        this.ec.WriteByte(
            (byte)this.fanConfig.FanSwitchRegister,
            (byte)this.fanConfig.FanSwitchValue);
    }

    return readWriteWords
        ? this.ec.ReadWord((byte)this.fanConfig.ReadRegister)
        : this.ec.ReadByte((byte)this.fanConfig.ReadRegister);
}
```

### Schritt 3.2 — `FanControl.cs` → Write-Verify-Retry-Logik

TPFanCtrl2 schreibt den Lüfterwert, wartet 100ms, liest zurück und wiederholt bis zu
5x (siehe `fanstuff.cpp` Z. 431-461). NBFC macht das nicht — es schreibt einmal und
prüft beim nächsten Poll-Zyklus (oft 3000ms später) ob der Wert noch stimmt.

Änderung in `UpdateEc()` (`FanControl.cs` Z. 405-434):

```csharp
private void UpdateEc(float temperature)
{
    bool reInitRequired = false;
    var speeds = new float[this.fans.Length];

    for (int i = 0; i < speeds.Length; i++)
    {
        speeds[i] = this.fans[i].GetCurrentSpeed();
        if (Math.Abs(speeds[i] - this.fans[i].TargetSpeed) > 15)
            reInitRequired = true;
    }

    if (!readOnly)
    {
        ApplyRegisterWriteConfigurations(reInitRequired);
    }

    for (int i = 0; i < this.fans.Length; i++)
    {
        float speed = Thread.VolatileRead(ref this.requestedSpeeds[i]);
        this.fans[i].SetTargetSpeed(speed, temperature, readOnly);

        // NEU: Write-Verify-Retry für ThinkPad
        if (!readOnly && this.config.FanWriteRetryCount > 1)
        {
            int retries = this.config.FanWriteRetryCount;
            for (int attempt = 1; attempt < retries; attempt++)
            {
                Thread.Sleep(100);
                float actual = this.fans[i].GetCurrentSpeed();
                if (Math.Abs(actual - this.fans[i].TargetSpeed) <= 15)
                    break;
                // Nochmal schreiben
                this.fans[i].SetTargetSpeed(speed, temperature, readOnly);
            }
        }
    }

    this.fanInfo = GetFanInformation();
}
```

### Schritt 3.3 — Poll-Intervall anpassen

Für P52 muss `EcPollInterval` deutlich kürzer sein als der Default (3000ms).
TPFanCtrl2 liest/schreibt ca. alle 1000ms. In der P52-Config auf `1000` setzen.

Prüfen, dass `MinPollInterval` (100ms in Release) nicht zu aggressiv ist.
Der Lenovo-Dienst schreibt alle ~50ms; NBFC muss nicht schneller sein, aber
1000ms ist ein guter Kompromiss zwischen CPU-Last und Reaktionszeit.

---

## Phase 4: P52 XML-Konfigurationsdatei

> Ziel: Eine funktionierende `Lenovo ThinkPad P52.xml`.

### Schritt 4.1 — Basis-Config erstellen

Datei: `Configs/Lenovo ThinkPad P52.xml`

```xml
<?xml version="1.0"?>
<FanControlConfigV2 xmlns:xsd="http://www.w3.org/2001/XMLSchema"
                    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <NotebookModel>Lenovo ThinkPad P52</NotebookModel>
  <Author>TODO</Author>
  <EcPollInterval>1000</EcPollInterval>
  <ReadWriteWords>false</ReadWriteWords>
  <CriticalTemperature>97</CriticalTemperature>
  <UseThinkPadEcProtocol>true</UseThinkPadEcProtocol>
  <FanWriteRetryCount>5</FanWriteRetryCount>
  <FanWriteRetryInterval>500</FanWriteRetryInterval>

  <FanConfigurations>
    <!-- Lüfter 1 (CPU) -->
    <FanConfiguration>
      <ReadRegister>47</ReadRegister>           <!-- 0x2F -->
      <WriteRegister>47</WriteRegister>         <!-- 0x2F -->
      <MinSpeedValue>0</MinSpeedValue>
      <MaxSpeedValue>7</MaxSpeedValue>
      <IndependentReadMinMaxValues>false</IndependentReadMinMaxValues>
      <ResetRequired>true</ResetRequired>
      <FanSpeedResetValue>128</FanSpeedResetValue>  <!-- 0x80 = BIOS-Kontrolle -->
      <FanDisplayName>CPU Fan</FanDisplayName>
      <FanSwitchRegister>49</FanSwitchRegister>     <!-- 0x31 -->
      <FanSwitchValue>64</FanSwitchValue>           <!-- 0x40 = Fan1; AM GERÄT VERIFIZIEREN -->
      <FanSpeedRegister>132</FanSpeedRegister>      <!-- 0x84 = RPM lo/hi -->
      <TemperatureThresholds>
        <TemperatureThreshold>
          <UpThreshold>0</UpThreshold>
          <DownThreshold>0</DownThreshold>
          <FanSpeed>0</FanSpeed>
        </TemperatureThreshold>
        <TemperatureThreshold>
          <UpThreshold>55</UpThreshold>
          <DownThreshold>45</DownThreshold>
          <FanSpeed>15</FanSpeed>
        </TemperatureThreshold>
        <TemperatureThreshold>
          <UpThreshold>65</UpThreshold>
          <DownThreshold>55</DownThreshold>
          <FanSpeed>30</FanSpeed>
        </TemperatureThreshold>
        <TemperatureThreshold>
          <UpThreshold>75</UpThreshold>
          <DownThreshold>65</DownThreshold>
          <FanSpeed>55</FanSpeed>
        </TemperatureThreshold>
        <TemperatureThreshold>
          <UpThreshold>85</UpThreshold>
          <DownThreshold>75</DownThreshold>
          <FanSpeed>80</FanSpeed>
        </TemperatureThreshold>
        <TemperatureThreshold>
          <UpThreshold>90</UpThreshold>
          <DownThreshold>80</DownThreshold>
          <FanSpeed>100</FanSpeed>
        </TemperatureThreshold>
      </TemperatureThresholds>
      <FanSpeedPercentageOverrides>
        <FanSpeedPercentageOverride>
          <FanSpeedPercentage>0</FanSpeedPercentage>
          <FanSpeedValue>0</FanSpeedValue>
          <TargetOperation>ReadWrite</TargetOperation>
        </FanSpeedPercentageOverride>
        <FanSpeedPercentageOverride>
          <FanSpeedPercentage>100</FanSpeedPercentage>
          <FanSpeedValue>7</FanSpeedValue>
          <TargetOperation>ReadWrite</TargetOperation>
        </FanSpeedPercentageOverride>
      </FanSpeedPercentageOverrides>
    </FanConfiguration>

    <!-- Lüfter 2 (GPU / Auxiliary) -->
    <FanConfiguration>
      <ReadRegister>47</ReadRegister>           <!-- 0x2F -->
      <WriteRegister>47</WriteRegister>         <!-- 0x2F -->
      <MinSpeedValue>0</MinSpeedValue>
      <MaxSpeedValue>7</MaxSpeedValue>
      <IndependentReadMinMaxValues>false</IndependentReadMinMaxValues>
      <ResetRequired>true</ResetRequired>
      <FanSpeedResetValue>128</FanSpeedResetValue>
      <FanDisplayName>GPU Fan</FanDisplayName>
      <FanSwitchRegister>49</FanSwitchRegister>     <!-- 0x31 -->
      <FanSwitchValue>65</FanSwitchValue>           <!-- 0x41 = Fan2; AM GERÄT VERIFIZIEREN -->
      <FanSpeedRegister>132</FanSpeedRegister>      <!-- 0x84 = RPM lo/hi -->
      <TemperatureThresholds>
        <TemperatureThreshold>
          <UpThreshold>0</UpThreshold>
          <DownThreshold>0</DownThreshold>
          <FanSpeed>0</FanSpeed>
        </TemperatureThreshold>
        <TemperatureThreshold>
          <UpThreshold>55</UpThreshold>
          <DownThreshold>45</DownThreshold>
          <FanSpeed>15</FanSpeed>
        </TemperatureThreshold>
        <TemperatureThreshold>
          <UpThreshold>65</UpThreshold>
          <DownThreshold>55</DownThreshold>
          <FanSpeed>30</FanSpeed>
        </TemperatureThreshold>
        <TemperatureThreshold>
          <UpThreshold>75</UpThreshold>
          <DownThreshold>65</DownThreshold>
          <FanSpeed>55</FanSpeed>
        </TemperatureThreshold>
        <TemperatureThreshold>
          <UpThreshold>85</UpThreshold>
          <DownThreshold>75</DownThreshold>
          <FanSpeed>80</FanSpeed>
        </TemperatureThreshold>
        <TemperatureThreshold>
          <UpThreshold>90</UpThreshold>
          <DownThreshold>80</DownThreshold>
          <FanSpeed>100</FanSpeed>
        </TemperatureThreshold>
      </TemperatureThresholds>
      <FanSpeedPercentageOverrides>
        <FanSpeedPercentageOverride>
          <FanSpeedPercentage>0</FanSpeedPercentage>
          <FanSpeedValue>0</FanSpeedValue>
          <TargetOperation>ReadWrite</TargetOperation>
        </FanSpeedPercentageOverride>
        <FanSpeedPercentageOverride>
          <FanSpeedPercentage>100</FanSpeedPercentage>
          <FanSpeedValue>7</FanSpeedValue>
          <TargetOperation>ReadWrite</TargetOperation>
        </FanSpeedPercentageOverride>
      </FanSpeedPercentageOverrides>
    </FanConfiguration>
  </FanConfigurations>

  <RegisterWriteConfigurations />
</FanControlConfigV2>
```

**WICHTIG**: Die Werte `FanSwitchValue` 64/65 (0x40/0x41) stammen aus der P50-Variante
von TPFanCtrl2. Beim P52 können sie identisch oder anders sein. Sie MÜSSEN am Gerät
mit EC-Monitor verifiziert werden bevor die Config produktiv eingesetzt wird.

### Schritt 4.2 — Temperatur-Schwellen kalibrieren

Die oben eingetragenen Schwellen sind konservative Startwerte. Auf dem echten P52:

1. Config laden, Lüfter auf Auto.
2. Unter Last (z.B. Prime95 + Furmark) die EC-Temperatursensoren loggen.
3. Schwellen anpassen bis Lüfterverhalten akzeptabel ist.
4. Sicherstellen, dass `CriticalTemperature` (97) über dem höchsten Schwellenwert liegt
   und dem ThrottleStop / Intel-Thermal-Limit entspricht.

---

## Phase 5: Build-Integration

> Ziel: Das neue Plugin wird gebaut und mit ausgeliefert.

### Schritt 5.1 — Solution-Datei erweitern

Das Projekt `StagWare.Plugins.ECThinkPad.csproj` zur Solution hinzufügen.
Configuration-Mappings analog zu `StagWare.Plugins.ECWindows` einrichten
(DebugWindows, ReleaseWindows).

### Schritt 5.2 — WiX Installer erweitern

In `Windows/Setup/NbfcSetup/Plugins.wxs` einen neuen Component-Block hinzufügen:

```xml
<Component Id="Plg.StagWare.Plugins.ECThinkPad"
           Guid="NEUE-GUID-HIER-GENERIEREN">
  <File Id="StagWare.Plugins.ECThinkPad.dll"
        Name="StagWare.Plugins.ECThinkPad.dll"
        DiskId="1"
        Vital="yes"
        KeyPath="yes"
        Source="$(var.StagWare.Plugins.ECThinkPad.TargetDir)StagWare.Plugins.ECThinkPad.dll">
    <?if $(var.Configuration) = "Release"?>
    <netfx:NativeImage Id="StagWare.Plugins.ECThinkPad.NativeImage"
                       Priority="1"
                       Platform="all"/>
    <?endif?>
  </File>
</Component>
```

Component zur `ComponentGroup "Plugins"` hinzufügen.
In `Product.wxs` referenzieren falls dort Component-Gruppen aufgelistet werden.

### Schritt 5.3 — Config-Editor

Der `Windows/ConfigEditor/` sollte die neuen Felder (FanSwitchRegister, FanSwitchValue,
UseThinkPadEcProtocol etc.) in der UI anzeigen. Mindestens:

- `ViewModels/MainViewModel.cs` erweitern
- Neue Eingabefelder in den XAML-Fenstern

Für den ersten Wurf kann das auch nachgelagert werden — die XML lässt sich auch
manuell editieren.

---

## Phase 6: Lenovo-Service-Mitigation (automatisiert)

> Ziel: NBFC warnt oder handelt, wenn Lenovo-Dienste aktiv sind.

### Schritt 6.1 — Service-Check beim Start

In `FanControl.Start()` (oder im Service-Host `StagWare.FanControl.Service`) prüfen,
ob bekannte Lenovo-Dienste laufen:

```csharp
private static readonly string[] ConflictingServices = new[]
{
    "LenovoFanTableService",
    "IBMPMSVC",
    // Name variiert je nach Lenovo-Version:
    "Lenovo Intelligent Cooling",
    "LenovoICM",
};

private void WarnConflictingServices()
{
    foreach (string name in ConflictingServices)
    {
        try
        {
            using (var sc = new ServiceController(name))
            {
                if (sc.Status == ServiceControllerStatus.Running)
                {
                    logger.Warn($"Conflicting service '{name}' is running. "
                        + "Fan control may not work correctly. "
                        + "Consider stopping this service.");
                }
            }
        }
        catch (InvalidOperationException)
        {
            // Service existiert nicht auf diesem System
        }
    }
}
```

### Schritt 6.2 — Optionaler Auto-Stop (mit Config-Flag)

Optionales Feature für Power-User: neues Config-Feld `StopConflictingServices`.
Wenn `true`, stoppt NBFC die oben genannten Dienste beim Start und startet sie
beim Beenden neu. **Achtung**: Erfordert Admin-Rechte und ist invasiv. Daher
standardmäßig `false` und nur als explizite Option.

---

## Phase 7: Tests

> Ziel: Korrektheit sicherstellen, sowohl Unit- als auch Geräte-Tests.

### Schritt 7.1 — Unit-Tests

Bestehende Test-Infrastruktur: `Tests/StagWare.FanControl.Tests/`.

Neue Tests:

- `ThinkPadEcPortIoTests`: Mock für ReadPort/WritePort, prüfen dass Type1/Type2-
  Fallback korrekt funktioniert.
- `FanSwitchTests`: Mock-EC, prüfen dass `ECWriteValue` bei gesetztem
  `FanSwitchRegister` die Sequenz Switch→Write ausführt.
- `RetryTests`: Prüfen dass Write-Verify-Retry-Logik korrekt abbricht bzw. wiederholt.
- `MutexTests`: Prüfen dass AcquireLock beide Mutexes (ISA + ThinkPad) erwirbt.
- `ConfigSerializationTests`: Alte Configs ohne neue Felder laden korrekt.
  Neue Configs mit allen Feldern serialisieren/deserialisieren korrekt.

### Schritt 7.2 — Gerätetest auf echtem P52

**WARNUNG**: EC-Register-Zugriffe können das System instabil machen. Nur auf
einem Gerät testen, bei dem Datenverlust akzeptabel ist. Immer zuerst Read-Only-Modus.

Testreihenfolge:

1. NBFC im Read-Only-Modus starten, EC-Monitor laufen lassen.
   Prüfen, dass beide Lüfter-Geschwindigkeiten korrekt gelesen werden.
2. Lenovo-Dienste stoppen (Schritt 0.1).
3. NBFC in den Steuermodus schalten, manuell 50% setzen.
   Prüfen, dass beide Lüfter reagieren.
4. NBFC stoppen → Lüfter müssen auf BIOS-Kontrolle (0x80) zurückfallen.
5. Stresstest: Last erzeugen, Smart-Modus prüfen.
6. Lenovo-Dienste wieder starten, prüfen dass NBFC die Warnung loggt.

---

## Phase 8: Dokumentation

### Schritt 8.1 — Wiki-Seite "ThinkPad P52"

Für das NBFC-Wiki (oder README) dokumentieren:

- Welche Lenovo-Dienste deaktiviert werden müssen
- Wie die Config installiert wird
- Bekannte Einschränkungen (EC-Verzögerung bei neuem ThinkPad-BIOS)
- Hinweis auf TPFanCtrl2 als Alternative

### Schritt 8.2 — Config-Kommentare

In der XML-Config Kommentare hinterlassen, die erklären welche Register-Werte
P52-spezifisch sind und wie man sie für andere ThinkPad-Modelle anpasst.

---

## Zusammenfassung: Dateien die geändert/erstellt werden

| Datei | Aktion | Phase |
|---|---|---|
| `Core/Plugins/StagWare.Plugins.ECThinkPad/ECThinkPad.cs` | NEU | 1 |
| `Core/Plugins/StagWare.Plugins.ECThinkPad/ThinkPadEcPortIo.cs` | NEU | 1 |
| `Core/Plugins/StagWare.Plugins.ECThinkPad/StagWare.Plugins.ECThinkPad.csproj` | NEU | 1 |
| `Core/Plugins/StagWare.Plugins.ECThinkPad/Properties/AssemblyInfo.cs` | NEU | 1 |
| `Core/StagWare.Configurations/FanConfiguration.cs` | ÄNDERN | 2 |
| `Core/StagWare.Configurations/FanControlConfigV2.cs` | ÄNDERN | 2 |
| `Core/StagWare.FanControl/Fan.cs` | ÄNDERN | 3 |
| `Core/StagWare.FanControl/FanControl.cs` | ÄNDERN | 3 |
| `Configs/Lenovo ThinkPad P52.xml` | NEU | 4 |
| `NBFC.sln` (oder wie die Solution heißt) | ÄNDERN | 5 |
| `Windows/Setup/NbfcSetup/Plugins.wxs` | ÄNDERN | 5 |
| `Windows/ConfigEditor/ViewModels/MainViewModel.cs` | ÄNDERN (optional) | 5 |
| Service-Host (FanControl.Service o.ä.) | ÄNDERN | 6 |
| `Tests/StagWare.FanControl.Tests/...` | NEU / ÄNDERN | 7 |

---

## Risiken & offene Fragen

1. **EC-Port-Typ**: Unklar ob P52 Type 1 (0x1604/0x1600) oder Type 2 (0x66/0x62) nutzt.
   Muss am Gerät getestet werden.
2. **Fan-Switch-Values**: 0x40/0x41 sind P50-Werte. P52 könnte andere verwenden.
3. **WinRing0 vs. TVicPort**: NBFC nutzt WinRing0, TPFanCtrl2 nutzt TVicPort.
   Beides sind Kernel-Treiber für Port-I/O. WinRing0 sollte funktionieren, aber
   wenn der P52-EC spezifisch auf TVicPort-Zugriffsmuster reagiert (unwahrscheinlich),
   müsste man den Treiber wechseln.
4. **Lenovo-Mutex-Name**: TPFanCtrl2 nutzt `Access_Thinkpad_EC`. Es ist unklar ob
   Lenovos eigene Dienste diesen Mutex respektieren oder einen anderen verwenden.
   Im schlimmsten Fall hilft der Mutex nur gegen andere Community-Tools, nicht gegen
   Lenovo selbst → Dienste müssen dann zwingend deaktiviert werden.
5. **BIOS-Updates**: Lenovo kann mit BIOS-Updates das EC-Verhalten ändern.
   Die Config muss möglicherweise nach BIOS-Updates angepasst werden.
6. **Andere ThinkPad-Modelle**: Die hier beschriebene Architektur (Plugin + Config-Felder)
   ist generisch genug für P50, P51, P53, T480, X1 Carbon etc. — aber jedes Modell
   braucht eine eigene verifizierte Config-Datei.

---

## Geschätzter Aufwand

| Phase | Aufwand | Abhängigkeit |
|---|---|---|
| Phase 0: HW-Vorbereitung | 1-2 Tage | Zugang zum P52 |
| Phase 1: ECThinkPad-Plugin | 3-5 Tage | Phase 0 |
| Phase 2: Config-Modell | 1 Tag | — |
| Phase 3: Kern-Logik | 2-3 Tage | Phase 1 + 2 |
| Phase 4: P52-Config | 1 Tag | Phase 0 + 2 |
| Phase 5: Build-Integration | 1 Tag | Phase 1 |
| Phase 6: Service-Mitigation | 1 Tag | — |
| Phase 7: Tests | 2-3 Tage | Alles |
| Phase 8: Dokumentation | 1 Tag | Phase 7 |
| **Gesamt** | **~13-17 Tage** | |

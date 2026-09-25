import AppKit

struct PlanetTuning: Codable {
    var cloudSpeed: Float = 4.15492
    var cloudEvolution: Float = 0.90074086
    var cloudCover: Float = 1.2022648
    var cloudHeight: Float = 0.018
    var cloudShadow: Float = 0.4294935
    var airDensity: Float = 1.8031871
    var waterWaves: Float = 1
    var waterGloss: Float = 0.45
    var waterRoughness: Float = 0.22
    var gasSpeed: Float = 18.629654
    var gasEvolution: Float = 20
    var gasDistortion: Float = 2.4435666
    var gasScale: Float = 18.86391
    var gasBands: Float = 4.5829415
    var gasShear: Float = 0.12365121
    init() {}
    enum CodingKeys: String, CodingKey { case cloudSpeed,cloudEvolution,cloudCover,cloudHeight,cloudShadow,airDensity,waterWaves,waterGloss,waterRoughness,gasSpeed,gasEvolution,gasDistortion,gasScale,gasBands,gasShear }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cloudSpeed = try c.decodeIfPresent(Float.self, forKey: .cloudSpeed) ?? cloudSpeed
        cloudEvolution = try c.decodeIfPresent(Float.self, forKey: .cloudEvolution) ?? cloudEvolution
        cloudCover = try c.decodeIfPresent(Float.self, forKey: .cloudCover) ?? cloudCover
        cloudHeight = try c.decodeIfPresent(Float.self, forKey: .cloudHeight) ?? cloudHeight
        cloudShadow = try c.decodeIfPresent(Float.self, forKey: .cloudShadow) ?? cloudShadow
        airDensity = try c.decodeIfPresent(Float.self, forKey: .airDensity) ?? airDensity
        waterWaves = try c.decodeIfPresent(Float.self, forKey: .waterWaves) ?? waterWaves
        waterGloss = try c.decodeIfPresent(Float.self, forKey: .waterGloss) ?? waterGloss
        waterRoughness = try c.decodeIfPresent(Float.self, forKey: .waterRoughness) ?? waterRoughness
        gasSpeed = try c.decodeIfPresent(Float.self, forKey: .gasSpeed) ?? gasSpeed
        gasEvolution = try c.decodeIfPresent(Float.self, forKey: .gasEvolution) ?? gasEvolution
        gasDistortion = try c.decodeIfPresent(Float.self, forKey: .gasDistortion) ?? gasDistortion
        gasScale = try c.decodeIfPresent(Float.self, forKey: .gasScale) ?? gasScale
        gasBands = try c.decodeIfPresent(Float.self, forKey: .gasBands) ?? gasBands
        gasShear = try c.decodeIfPresent(Float.self, forKey: .gasShear) ?? gasShear
    }
    static let key = "planet.material.tuning.v1"
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: key), let result = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return result.clamped
    }
    var clamped: Self {
        var copy = self
        for item in Self.controls + Self.gasControls { copy[keyPath:item.path] = min(item.max,max(item.min,copy[keyPath:item.path].isFinite ? copy[keyPath:item.path] : Self()[keyPath:item.path])) }
        return copy
    }
    func json() -> String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        return String(data:(try? encoder.encode(self)) ?? Data(),encoding:.utf8) ?? "{}"
    }
    struct Control { let name:String; let path:WritableKeyPath<PlanetTuning,Float>; let min:Float; let max:Float }
    static let controls:[Control] = [
        .init(name:"Cloud drift",path:\.cloudSpeed,min:0,max:20),
        .init(name:"Cloud evolution",path:\.cloudEvolution,min:0,max:20),
        .init(name:"Cloud coverage",path:\.cloudCover,min:0,max:2),
        .init(name:"Cloud altitude",path:\.cloudHeight,min:0.003,max:0.05),
        .init(name:"Cloud shadows",path:\.cloudShadow,min:0,max:0.7),
        .init(name:"Atmosphere",path:\.airDensity,min:0,max:3),
        .init(name:"Water ripples",path:\.waterWaves,min:0,max:3),
        .init(name:"Sun reflection",path:\.waterGloss,min:0,max:1.5),
        .init(name:"Water roughness",path:\.waterRoughness,min:0.06,max:0.6)
    ]
    static let gasControls:[Control] = [
        .init(name:"Gas rotation",path:\.gasSpeed,min:-20,max:20),
        .init(name:"Gas vector evolution",path:\.gasEvolution,min:0,max:20),
        .init(name:"Vector distortion",path:\.gasDistortion,min:0,max:3),
        .init(name:"Pattern scale",path:\.gasScale,min:2,max:20),
        .init(name:"Band frequency",path:\.gasBands,min:4,max:70),
        .init(name:"Differential wind",path:\.gasShear,min:0,max:1),
        .init(name:"Atmosphere",path:\.airDensity,min:0,max:3)
    ]

}

/// Opt-in artist controls, separate from the children's landing interface.
final class PlanetTuningPanel: NSPanel {
    var onChange:((PlanetTuning)->Void)?
    var onType:((Int)->Void)?
    private var items = PlanetTuning.controls
    private var tuning:PlanetTuning
    private var sliders:[NSSlider]=[]
    private var labels:[NSTextField]=[]
    private let status=NSTextField(labelWithString:"Settings apply to all planet types. Type is preview only.")
    init(tuning:PlanetTuning, type:Int) {
        self.tuning=tuning
        super.init(contentRect:NSRect(x:0,y:0,width:390,height:535),styleMask:[.titled,.closable,.utilityWindow],backing:.buffered,defer:false)
        title="Planet workshop · E"
        isReleasedWhenClosed=false
        let content=NSView(frame:NSRect(x:0,y:0,width:390,height:535));contentView=content
        let types=NSPopUpButton(frame:NSRect(x:18,y:488,width:354,height:30))
        types.addItems(withTitles:Atmosphere.all.map(\.name));types.selectItem(at:type)
        types.target=self;types.action=#selector(changeType(_:));content.addSubview(types)
        for (i,item) in PlanetTuning.controls.enumerated() {
            let y=CGFloat(450-i*43)
            let label=NSTextField(labelWithString:"");label.frame=NSRect(x:18,y:y,width:354,height:18)
            label.font=NSFont.systemFont(ofSize:12);content.addSubview(label);labels.append(label)
            let slider=NSSlider(value:Double(tuning[keyPath:item.path]),minValue:Double(item.min),maxValue:Double(item.max),target:self,action:#selector(change(_:)))
            slider.frame=NSRect(x:18,y:y-23,width:354,height:22);slider.tag=i;slider.isContinuous=true
            content.addSubview(slider);sliders.append(slider)
        }
        for (i,title) in ["Save","Copy JSON","Paste JSON","Reset"].enumerated() {
            let button=NSButton(title:title,target:self,action:#selector(action(_:)));button.tag=i
            button.frame=NSRect(x:14+i*94,y:40,width:92,height:30);button.bezelStyle = .rounded;content.addSubview(button)
        }
        status.frame=NSRect(x:18,y:8,width:354,height:28);status.font=NSFont.systemFont(ofSize:10);status.maximumNumberOfLines=2
        content.addSubview(status);selectControls(type);refresh()
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 14 || event.keyCode == 53 { orderOut(nil); parent?.makeKey() }
        else { super.keyDown(with:event) }
    }
    var reviewControlsFit:Bool { contentView.map { content in content.subviews.allSatisfy { content.bounds.contains($0.frame) } } ?? false }
    private func refresh() {
        for (i,item) in items.enumerated(){sliders[i].floatValue=tuning[keyPath:item.path];labels[i].stringValue=String(format:"%@  %.3f",item.name,tuning[keyPath:item.path])}
    }
    @objc private func change(_ sender:NSSlider){tuning[keyPath:items[sender.tag].path]=sender.floatValue;refresh();onChange?(tuning)}
    private func selectControls(_ index:Int) {
        let name=Atmosphere.all[index].name.lowercased()
        let gas=name.contains("hydrogen") || name.contains("ice giant")
        items=gas ? PlanetTuning.gasControls : PlanetTuning.controls
        for i in sliders.indices {
            sliders[i].isHidden=i >= items.count; labels[i].isHidden=i >= items.count
            if i < items.count { sliders[i].minValue=Double(items[i].min);sliders[i].maxValue=Double(items[i].max) }
        }
        refresh()
        status.stringValue=gas ? "Gas bands only — no separate cloud layer. Shared gas settings." : "Cloud/water settings. Planet type is preview only."
    }
    @objc private func changeType(_ sender:NSPopUpButton){selectControls(sender.indexOfSelectedItem);onType?(sender.indexOfSelectedItem)}
    @objc private func action(_ sender:NSButton){
        switch sender.tag {
        case 0:
            UserDefaults.standard.set(try? JSONEncoder().encode(tuning),forKey:PlanetTuning.key)
            status.stringValue="Saved. These settings load on future planet visits."
        case 1:
            NSPasteboard.general.clearContents();NSPasteboard.general.setString(tuning.json(),forType:.string)
            status.stringValue="JSON copied — paste it into the conversation."
        case 2:
            guard let text=NSPasteboard.general.string(forType:.string),let data=text.data(using:.utf8),let parsed=try? JSONDecoder().decode(PlanetTuning.self,from:data) else { status.stringValue="Clipboard is not a valid planet configuration.";return }
            tuning=parsed.clamped;refresh();onChange?(tuning);status.stringValue="Imported preview. Press Save to keep it."
        default:tuning=PlanetTuning();refresh();onChange?(tuning);status.stringValue="Default preview restored. Press Save to keep it."
        }
    }
}

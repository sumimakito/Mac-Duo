import AppKit

struct ImagePlacement {
    var fill = true
    var zoom: CGFloat = 1
    var x: CGFloat = 0
    var y: CGFloat = 0
    func rect(source: CGSize, canvas: CGSize) -> CGRect {
        let ratios = (canvas.width/source.width, canvas.height/source.height)
        let scale = (fill ? max(ratios.0, ratios.1) : min(ratios.0, ratios.1)) * zoom
        let size = CGSize(width: source.width*scale, height: source.height*scale)
        return CGRect(x: (canvas.width-size.width)/2 + x*abs(canvas.width-size.width)/2,
                      y: (canvas.height-size.height)/2 + y*abs(canvas.height-size.height)/2,
                      width: size.width, height: size.height)
    }
    func render(_ image: CGImage, size: CGSize) -> CGImage? {
        guard let c = CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.setFillColor(NSColor.black.cgColor); c.fill(CGRect(origin:.zero,size:size))
        c.interpolationQuality = .high
        c.draw(image,in:rect(source:CGSize(width:image.width,height:image.height),canvas:size))
        return c.makeImage()
    }
}

@MainActor
final class ImageCropEditor: NSObject {
    let original: CGImage
    let outputSize: CGSize
    var placement: ImagePlacement
    let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:620,height:570),styleMask:[.titled],backing:.buffered,defer:false)
    let preview = NSImageView()
    let mode = NSSegmentedControl(labels:["Fill / crop","Fit whole image"],trackingMode:.selectOne,target:nil,action:nil)
    let zoom = NSSlider(value:1,minValue:1,maxValue:4,target:nil,action:nil)
    let horizontal = NSSlider(value:0,minValue:-1,maxValue:1,target:nil,action:nil)
    let vertical = NSSlider(value:0,minValue:-1,maxValue:1,target:nil,action:nil)
    var completion: ((CGImage, ImagePlacement) -> Void)?
    var onClose: (() -> Void)?
    private let language = SettingsLanguage(rawValue: UserDefaults.standard.string(forKey:"settingsLanguage") ?? "") ?? .preferred
    private func localized(_ text: String) -> String { language.localized(text) }
    init(image:CGImage, size:CGSize, placement:ImagePlacement) {
        original=image; outputSize=size; self.placement=placement
        super.init()
        panel.title=localized("Crop and resize image"); panel.isReleasedWhenClosed=false
        let root=NSStackView(); root.orientation = .vertical; root.spacing=14; root.alignment = .centerX
        root.translatesAutoresizingMaskIntoConstraints=false; panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:panel.contentView!.leadingAnchor,constant:24),root.trailingAnchor.constraint(equalTo:panel.contentView!.trailingAnchor,constant:-24),root.topAnchor.constraint(equalTo:panel.contentView!.topAnchor,constant:24)])
        preview.imageScaling = .scaleProportionallyUpOrDown
        root.addArrangedSubview(preview)
        preview.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        preview.heightAnchor.constraint(equalToConstant:300).isActive=true
        mode.setLabel(localized("Fill / crop"),forSegment:0); mode.setLabel(localized("Fit whole image"),forSegment:1)
        mode.target=self; mode.action=#selector(modeChanged); root.addArrangedSubview(mode)
        for (name,control) in [(localized("Size"),zoom),(localized("Left / right"),horizontal),(localized("Down / up"),vertical)] {
            control.target=self; control.action=#selector(changed); control.isContinuous=true; control.setAccessibilityLabel(name)
            let label=NSTextField(labelWithString:name); label.widthAnchor.constraint(equalToConstant:90).isActive=true
            let row=NSStackView(views:[label,control]); row.spacing=12; root.addArrangedSubview(row); row.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        }
        let hint=NSTextField(labelWithString:localized("Proportions stay unchanged. Fit adds black borders where needed.")); hint.font = .systemFont(ofSize:11); root.addArrangedSubview(hint)
        let reset=NSButton(title:localized("Reset"),target:self,action:#selector(resetImage))
        let cancel=NSButton(title:localized("Cancel"),target:self,action:#selector(cancel)); cancel.keyEquivalent="\u{1b}"
        let apply=NSButton(title:localized("Use image"),target:self,action:#selector(apply)); apply.keyEquivalent="\r"
        root.addArrangedSubview(NSStackView(views:[reset,cancel,apply]))
        syncControls(); refresh()
    }
    func syncControls() { mode.selectedSegment=placement.fill ? 0 : 1; zoom.doubleValue=Double(placement.zoom); horizontal.doubleValue=Double(placement.x); vertical.doubleValue=Double(placement.y) }
    func refresh() {
        let scale=min(1,1100/outputSize.width)
        let size=CGSize(width:max(1,floor(outputSize.width*scale)),height:max(1,floor(outputSize.height*scale)))
        if let image=placement.render(original,size:size) { preview.image=NSImage(cgImage:image,size:CGSize(width:480,height:480*size.height/size.width)) }
    }
    @objc func modeChanged() { placement.fill=mode.selectedSegment==0; placement.zoom=1; placement.x=0; placement.y=0; syncControls(); refresh() }
    @objc func changed() { placement.zoom=CGFloat(zoom.doubleValue); placement.x=CGFloat(horizontal.doubleValue); placement.y=CGFloat(vertical.doubleValue); refresh() }
    @objc func resetImage() { placement=ImagePlacement(); syncControls(); refresh() }
    @objc func cancel() { panel.orderOut(nil); onClose?() }
    @objc func apply() {
        guard let image=placement.render(original,size:outputSize) else { NSSound.beep(); return }
        completion?(image,placement); cancel()
    }
}

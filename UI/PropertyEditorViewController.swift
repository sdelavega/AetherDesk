import AppKit
import Foundation
import ObjectiveC.runtime

/// Renders a native AppKit editor for the current wallpaper's
/// `LivelyProperties.json`. Changes fire a notification on the
/// shared NotificationCenter with `{ "key": String, "value": Any }`.
///
/// Observers (PreferencesWindowController) forward the event to
/// WallpaperManager.updateProperty(_:value:for:).
final class PropertyEditorViewController: NSViewController {

    static let propertyChangedNotification =
        Notification.Name("AetherDesk.propertyChanged")

    private let bundle: WallpaperBundle
    private var propertyControls: [String: NSControl] = [:]

    init(bundle: WallpaperBundle) {
        self.bundle = bundle
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        var lastAnchor = contentView.topAnchor

        if let properties = bundle.properties, !properties.isEmpty {
            for prop in properties {
                let control = createControl(for: prop)
                let rowView = createRowView(for: prop, control: control)
                contentView.addSubview(rowView)

                NSLayoutConstraint.activate([
                    rowView.topAnchor.constraint(equalTo: lastAnchor, constant: 10),
                    rowView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
                    rowView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10)
                ])

                lastAnchor = rowView.bottomAnchor
                propertyControls[prop.name] = control
            }
        } else {
            let empty = NSTextField(labelWithString: "This wallpaper has no adjustable properties.")
            empty.textColor = .secondaryLabelColor
            empty.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
                empty.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
            ])
            lastAnchor = empty.bottomAnchor
        }

        contentView.bottomAnchor.constraint(equalTo: lastAnchor, constant: 20).isActive = true

        scrollView.documentView = contentView
        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        self.view = scrollView
    }

    // MARK: Rows / controls

    private func createRowView(for prop: LivelyProperty, control: NSControl) -> NSView {
        let rowView = NSView()
        rowView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: prop.description ?? prop.name)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        rowView.addSubview(label)

        control.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(control)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: rowView.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 140),

            control.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            control.trailingAnchor.constraint(equalTo: rowView.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),

            rowView.heightAnchor.constraint(equalToConstant: 30)
        ])

        return rowView
    }

    private func createControl(for prop: LivelyProperty) -> NSControl {
        let propertyType = PropertyType(from: prop.type)
        let target = ControlTarget(key: prop.name, editor: self)

        // Keep a strong ref in the control's identifier-adjacent storage by
        // using associated objects via the target. Targets live as long as
        // the editor because `propertyControls` retains the control and the
        // control retains its target.
        switch propertyType {
        case .range:
            let slider = NSSlider(value: prop.value.doubleValue ?? 0,
                                  minValue: prop.min?.doubleValue ?? 0,
                                  maxValue: prop.max?.doubleValue ?? 100,
                                  target: target,
                                  action: #selector(ControlTarget.sliderChanged(_:)))
            slider.allowsTickMarkValuesOnly = false
            slider.isContinuous = true
            target.retain(in: slider)
            return slider

        case .bool, .checkbox:
            let checkbox = NSButton(checkboxWithTitle: "",
                                    target: target,
                                    action: #selector(ControlTarget.checkboxChanged(_:)))
            checkbox.state = (prop.value.boolValue ?? false) ? .on : .off
            target.retain(in: checkbox)
            return checkbox

        case .choice, .dropdown:
            let popup = NSPopUpButton()
            popup.target = target
            popup.action = #selector(ControlTarget.popupChanged(_:))
            if let items = prop.items {
                for item in items {
                    popup.addItem(withTitle: String(describing: item.value))
                }
            }
            if let currentValue = prop.value.stringValue {
                popup.selectItem(withTitle: currentValue)
            } else if let currentInt = prop.value.intValue,
                      currentInt >= 0 && currentInt < popup.numberOfItems {
                popup.selectItem(at: currentInt)
            }
            target.retain(in: popup)
            return popup

        case .color:
            let colorWell = NSColorWell()
            colorWell.target = target
            colorWell.action = #selector(ControlTarget.colorChanged(_:))
            if let colorString = prop.value.stringValue {
                colorWell.color = NSColor(hexString: colorString) ?? .white
            }
            target.retain(in: colorWell)
            return colorWell

        case .text:
            let textField = NSTextField()
            textField.stringValue = prop.value.stringValue ?? ""
            textField.placeholderString = prop.description ?? "Enter value"
            textField.target = target
            textField.action = #selector(ControlTarget.textChanged(_:))
            target.retain(in: textField)
            return textField

        case .unknown:
            let textField = NSTextField(labelWithString: String(describing: prop.value.value))
            textField.textColor = .secondaryLabelColor
            return textField
        }
    }

    fileprivate func notifyPropertyChange(for key: String, value: Any) {
        NotificationCenter.default.post(
            name: Self.propertyChangedNotification,
            object: bundle.id,
            userInfo: ["key": key, "value": value]
        )
    }
}

// MARK: - ControlTarget

/// Per-control target/selector holder. Captures the property key so the
/// change handler can dispatch the correct `(key, value)` update.
private final class ControlTarget: NSObject {
    let key: String
    weak var editor: PropertyEditorViewController?

    init(key: String, editor: PropertyEditorViewController) {
        self.key = key
        self.editor = editor
    }

    /// Keep this target alive for the lifetime of `control` by attaching it
    /// via `objc_setAssociatedObject`.
    func retain(in control: NSControl) {
        objc_setAssociatedObject(control,
                                 &AssociatedKeys.controlTarget,
                                 self,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @objc func sliderChanged(_ sender: NSSlider)   { editor?.notifyPropertyChange(for: key, value: sender.doubleValue) }
    @objc func checkboxChanged(_ sender: NSButton) { editor?.notifyPropertyChange(for: key, value: sender.state == .on) }
    @objc func popupChanged(_ sender: NSPopUpButton) {
        let value: Any = sender.titleOfSelectedItem ?? sender.indexOfSelectedItem
        editor?.notifyPropertyChange(for: key, value: value)
    }
    @objc func colorChanged(_ sender: NSColorWell) {
        editor?.notifyPropertyChange(for: key, value: sender.color.hexString)
    }
    @objc func textChanged(_ sender: NSTextField)  { editor?.notifyPropertyChange(for: key, value: sender.stringValue) }
}

private enum AssociatedKeys {
    static var controlTarget: UInt8 = 0
}

// MARK: - NSColor hex helpers

extension NSColor {

    /// Parse a CSS-style hex color string. Supports `#rgb`, `#rrggbb`, and
    /// `#rrggbbaa`. Returns nil for unsupported formats.
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }

        // Expand #rgb to #rrggbb.
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }

        guard s.count == 6 || s.count == 8 else { return nil }

        var rgb: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&rgb) else { return nil }

        let r, g, b, a: CGFloat
        if s.count == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
            a = 1.0
        } else {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    /// CSS-style `#rrggbb` encoding of the current color (converted through sRGB).
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(c.redComponent   * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent  * 255))
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

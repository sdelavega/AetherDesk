import AppKit
import Foundation

class PropertyEditorViewController: NSViewController {

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
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        var lastAnchor = contentView.topAnchor

        if let properties = bundle.properties {
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
        }

        contentView.bottomAnchor.constraint(equalTo: lastAnchor, constant: 20).isActive = true

        scrollView.documentView = contentView

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        self.view = scrollView
    }

    private func createRowView(for prop: LivelyProperty, control: NSControl) -> NSView {
        let rowView = NSView()
        rowView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: prop.name)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        rowView.addSubview(label)

        control.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(control)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: rowView.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 120),

            control.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            control.trailingAnchor.constraint(equalTo: rowView.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),

            rowView.heightAnchor.constraint(equalToConstant: 30)
        ])

        return rowView
    }

    private func createControl(for prop: LivelyProperty) -> NSControl {
        let propertyType = PropertyType(from: prop.type)

        switch propertyType {
        case .range:
            let slider = NSSlider()
            slider.minValue = prop.min?.doubleValue ?? 0
            slider.maxValue = prop.max?.doubleValue ?? 100
            slider.doubleValue = prop.value.doubleValue ?? 50
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
            return slider

        case .bool, .checkbox:
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxChanged(_:)))
            checkbox.state = (prop.value.boolValue ?? false) ? .on : .off
            return checkbox

        case .choice, .dropdown:
            let popup = NSPopUpButton()
            if let items = prop.items {
                for item in items {
                    popup.addItem(withTitle: String(describing: item.value))
                }
            }
            if let currentValue = prop.value.stringValue {
                popup.selectItem(withTitle: currentValue)
            }
            return popup

        case .color:
            let colorWell = NSColorWell()
            if let colorString = prop.value.stringValue {
                colorWell.color = NSColor(colorString: colorString) ?? .white
            }
            return colorWell

        case .text:
            let textField = NSTextField()
            textField.stringValue = prop.value.stringValue ?? ""
            textField.placeholderString = "Enter value"
            return textField

        default:
            let textField = NSTextField()
            textField.stringValue = String(describing: prop.value.value)
            textField.isEditable = false
            return textField
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        notifyPropertyChange(for: "slider", value: sender.doubleValue)
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        notifyPropertyChange(for: "checkbox", value: sender.state == .on)
    }

    private func notifyPropertyChange(for key: String, value: Any) {
        NotificationCenter.default.post(
            name: Notification.Name("AetherDesk.propertyChanged"),
            object: nil,
            userInfo: ["key": key, "value": value]
        )
    }
}

extension NSColor {
    convenience init?(colorString: String) {
        var hexString = colorString.trimmingCharacters(in: .whitespacesAndNewlines)

        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }

        guard hexString.count == 6 else { return nil }

        var rgbValue: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgbValue)

        let red = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue, alpha: 1.0)
    }
}

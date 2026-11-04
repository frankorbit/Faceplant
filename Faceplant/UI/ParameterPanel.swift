import UIKit

/// 放置页的调参面板：一组滑杆直接改 `FaceRenderParameters`，方便真机上对着原版视频调手感。
final class ParameterPanel: UIView {
    var onChange: ((FaceRenderParameters) -> Void)?

    private(set) var parameters = FaceRenderParameters.standard {
        didSet { onChange?(parameters) }
    }

    private let stack = UIStackView()
    private let hintLabel = UILabel()
    private var sliders: [UISlider] = []
    private var valueLabels: [UILabel] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        layer.cornerRadius = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 6
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        for (index, descriptor) in FaceRenderParameters.sliders.enumerated() {
            stack.addArrangedSubview(makeRow(index: index, descriptor: descriptor))
        }

        // 正在拖的那一项的说明，告诉人调大会看到什么
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        hintLabel.numberOfLines = 0
        hintLabel.text = "拖动滑杆，这里会说明它控制什么"
        stack.addArrangedSubview(hintLabel)

        var config = UIButton.Configuration.plain()
        config.title = "重置"
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0)
        let reset = UIButton(configuration: config)
        reset.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)
        stack.addArrangedSubview(reset)
        refreshLabels()
    }

    private func makeRow(index: Int, descriptor: FaceRenderParameters.Slider) -> UIStackView {
        let title = UILabel()
        title.text = descriptor.title
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .white
        title.setContentHuggingPriority(.required, for: .horizontal)
        title.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let value = UILabel()
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .white
        value.textAlignment = .right
        value.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let slider = UISlider()
        slider.minimumValue = descriptor.range.lowerBound
        slider.maximumValue = descriptor.range.upperBound
        slider.value = parameters[keyPath: descriptor.keyPath]
        slider.tag = index
        slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderTouched(_:)), for: .touchDown)

        let row = UIStackView(arrangedSubviews: [title, slider, value])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        sliders.append(slider)
        valueLabels.append(value)
        return row
    }

    @objc private func sliderChanged(_ slider: UISlider) {
        let descriptor = FaceRenderParameters.sliders[slider.tag]
        parameters[keyPath: descriptor.keyPath] = slider.value
        hintLabel.text = "\(descriptor.title)：\(descriptor.hint)"
        refreshLabels()
    }

    @objc private func sliderTouched(_ slider: UISlider) {
        let descriptor = FaceRenderParameters.sliders[slider.tag]
        hintLabel.text = "\(descriptor.title)：\(descriptor.hint)"
    }

    @objc private func resetTapped() {
        parameters = .standard
        for (index, descriptor) in FaceRenderParameters.sliders.enumerated() {
            sliders[index].value = parameters[keyPath: descriptor.keyPath]
        }
        refreshLabels()
    }

    private func refreshLabels() {
        for (index, descriptor) in FaceRenderParameters.sliders.enumerated() {
            valueLabels[index].text = String(format: "%.3f", parameters[keyPath: descriptor.keyPath])
        }
    }
}

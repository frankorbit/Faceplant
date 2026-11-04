import UIKit

/// 调参面板：每个参数一行，滑杆两边有 − / + 按钮按固定步长微调，方便真机上对着原版视频调手感。
/// 行数多时整体可滚动，宿主用高度约束限制最大高度。
final class ParameterPanel: UIView {
    var onChange: ((FaceRenderParameters) -> Void)?

    private(set) var parameters = FaceRenderParameters.standard {
        didSet { onChange?(parameters) }
    }

    private let scrollView = UIScrollView()
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
        clipsToBounds = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        addSubview(scrollView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 4
        scrollView.addSubview(stack)

        // 面板高度跟着内容走；宿主给一个"不超过屏幕多少"的更高优先级约束，超出就滚动
        let contentHeight = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 20)
        contentHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -24),
            contentHeight,
        ])

        for (index, descriptor) in FaceRenderParameters.sliders.enumerated() {
            stack.addArrangedSubview(makeRow(index: index, descriptor: descriptor))
        }

        // 正在调的那一项的说明，告诉人调大会看到什么
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        hintLabel.numberOfLines = 0
        hintLabel.text = "拖滑杆或点 − / +，这里会说明它控制什么"
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
        title.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let value = UILabel()
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .white
        value.textAlignment = .right
        value.widthAnchor.constraint(equalToConstant: 46).isActive = true

        let slider = UISlider()
        slider.minimumValue = descriptor.range.lowerBound
        slider.maximumValue = descriptor.range.upperBound
        slider.value = parameters[keyPath: descriptor.keyPath]
        slider.tag = index
        slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderTouched(_:)), for: .touchDown)

        let minus = makeStepButton(title: "−", index: index, action: #selector(minusTapped(_:)))
        let plus = makeStepButton(title: "+", index: index, action: #selector(plusTapped(_:)))

        let row = UIStackView(arrangedSubviews: [title, minus, slider, plus, value])
        row.axis = .horizontal
        row.spacing = 4
        row.alignment = .center
        sliders.append(slider)
        valueLabels.append(value)
        return row
    }

    private func makeStepButton(title: String, index: Int, action: Selector) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.2)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
        let button = UIButton(configuration: config)
        button.tag = index
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    // MARK: - 事件

    @objc private func sliderChanged(_ slider: UISlider) {
        apply(value: slider.value, index: slider.tag)
    }

    @objc private func sliderTouched(_ slider: UISlider) {
        showHint(index: slider.tag)
    }

    @objc private func minusTapped(_ button: UIButton) {
        step(index: button.tag, direction: -1)
    }

    @objc private func plusTapped(_ button: UIButton) {
        step(index: button.tag, direction: 1)
    }

    @objc private func resetTapped() {
        parameters = .standard
        for (index, descriptor) in FaceRenderParameters.sliders.enumerated() {
            sliders[index].value = parameters[keyPath: descriptor.keyPath]
        }
        refreshLabels()
    }

    /// 按步长加减，结果限制在滑杆范围内并对齐到步长，避免 0.30000001 这类显示
    private func step(index: Int, direction: Float) {
        let descriptor = FaceRenderParameters.sliders[index]
        let current = parameters[keyPath: descriptor.keyPath]
        let stepped = ((current / descriptor.step).rounded() + direction) * descriptor.step
        let clamped = min(max(stepped, descriptor.range.lowerBound), descriptor.range.upperBound)
        sliders[index].setValue(clamped, animated: true)
        apply(value: clamped, index: index)
    }

    private func apply(value: Float, index: Int) {
        let descriptor = FaceRenderParameters.sliders[index]
        parameters[keyPath: descriptor.keyPath] = value
        showHint(index: index)
        refreshLabels()
    }

    private func showHint(index: Int) {
        let descriptor = FaceRenderParameters.sliders[index]
        hintLabel.text = "\(descriptor.title)：\(descriptor.hint)"
    }

    private func refreshLabels() {
        for (index, descriptor) in FaceRenderParameters.sliders.enumerated() {
            valueLabels[index].text = descriptor.format(parameters[keyPath: descriptor.keyPath])
        }
    }
}

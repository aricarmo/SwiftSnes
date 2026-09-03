//  NotchPanelShape.swift
//  Contorno do painel: faixa do notch (largura fixa) em cima e corpo embaixo.

import SwiftUI

/// Quando o corpo é mais largo, sai da faixa com ombros: filete côncavo junto
/// à faixa e canto convexo na borda externa. A largura do corpo anima na troca
/// de conteúdo. O topo da faixa tem orelhas côncavas para fora, como o
/// entalhe físico; o `rect` reserva `topFlareRadius` de cada lado para elas.
struct NotchPanelShape: Shape {
    var headerWidth: CGFloat
    var headerHeight: CGFloat
    var bodyWidth: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(headerWidth, bodyWidth) }
        set { headerWidth = newValue.first; bodyWidth = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let flare = NotchMetrics.topFlareRadius
        let total = rect.width
        let header = min(headerWidth, total - 2 * flare)
        let body = min(max(bodyWidth, header), total - 2 * flare)
        let h = rect.height
        let y0 = min(headerHeight, h)
        let hx0 = ((total - header) / 2).rounded()
        let hx1 = hx0 + header
        let bottom = NotchMetrics.bottomCornerRadius

        var p = Path()
        // Ainda dentro da faixa: só a pílula do notch, com orelhas em cima e
        // cantos do entalhe embaixo.
        guard h > y0 + 0.5 else {
            // Orelhas discretas; o raio maior do painel aberto vem com o corpo.
            let r = min(NotchMetrics.notchCornerRadius, h / 2)
            let f = max(0, min(NotchMetrics.pillFlareRadius, h - r))
            p.move(to: CGPoint(x: hx0 - f, y: 0))
            p.addLine(to: CGPoint(x: hx1 + f, y: 0))
            p.addArc(center: CGPoint(x: hx1 + f, y: f), radius: f,
                     startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
            p.addLine(to: CGPoint(x: hx1, y: h - r))
            p.addArc(center: CGPoint(x: hx1 - r, y: h - r), radius: r,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: hx0 + r, y: h))
            p.addArc(center: CGPoint(x: hx0 + r, y: h - r), radius: r,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: hx0, y: f))
            p.addArc(center: CGPoint(x: hx0 - f, y: f), radius: f,
                     startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
            p.closeSubpath()
            return p
        }
        // Ao recolher, o corpo afunila até a largura da faixa enquanto some:
        // sem isso restaria uma lasca larga e fina sob o notch, e no fim um
        // salto para a pílula. Afunila nos últimos `taper` pontos de altura.
        let taper: CGFloat = 2 * (NotchMetrics.shoulderRadius + bottom)
        let t = min(1, (h - y0) / taper)
        let eased = t * t * (3 - 2 * t)
        let half = ((body - header) / 2 * eased).rounded()
        let bx0 = hx0 - half
        let bx1 = hx1 + half
        let room = (h - y0) / 2
        let c = min(bottom, room)
        let r = min(NotchMetrics.shoulderRadius * eased, room, half)
        // Orelhas: crescem do raio da pílula até o do painel junto com o corpo,
        // e só cedem espaço ao filete do ombro.
        let pill = NotchMetrics.pillFlareRadius
        let f = max(0, min(pill + (flare - pill) * eased, y0 - r))

        p.move(to: CGPoint(x: hx0 - f, y: 0))
        p.addLine(to: CGPoint(x: hx1 + f, y: 0))
        p.addArc(center: CGPoint(x: hx1 + f, y: f), radius: f,
                 startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
        p.addLine(to: CGPoint(x: hx1, y: y0 - r))
        // Filete côncavo: da lateral da faixa para o topo do corpo.
        p.addArc(center: CGPoint(x: hx1 + r, y: y0 - r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: bx1 - r, y: y0))
        p.addArc(center: CGPoint(x: bx1 - r, y: y0 + r), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: bx1, y: h - c))
        p.addArc(center: CGPoint(x: bx1 - c, y: h - c), radius: c,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: bx0 + c, y: h))
        p.addArc(center: CGPoint(x: bx0 + c, y: h - c), radius: c,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: bx0, y: y0 + r))
        p.addArc(center: CGPoint(x: bx0 + r, y: y0 + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: hx0 - r, y: y0))
        p.addArc(center: CGPoint(x: hx0 - r, y: y0 - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: hx0, y: f))
        p.addArc(center: CGPoint(x: hx0 - f, y: f), radius: f,
                 startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
        p.closeSubpath()
        return p
    }
}

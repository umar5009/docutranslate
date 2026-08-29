import SwiftUI

struct AnimatedSplashView: View {
    let onFinish: () -> Void

    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0
    @State private var docOpacity: Double = 0
    @State private var docOffset: CGFloat = 24
    @State private var signatureProgress: CGFloat = 0
    @State private var signatureOpacity: Double = 0
    @State private var stampOffset: CGFloat = -70
    @State private var stampScale: CGFloat = 1.35
    @State private var stampOpacity: Double = 0
    @State private var stampRotation: Double = -18
    @State private var impactScale: CGFloat = 0.3
    @State private var impactOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var titleOffset: CGFloat = 16
    @State private var exitOpacity: Double = 1

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "#1a56d6"), Color(hex: "#0f3a9e")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                ZStack {
                    // Document card
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white)
                        .frame(width: 220, height: 280)
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                        .overlay(documentLines)
                        .opacity(docOpacity)
                        .offset(y: docOffset)

                    // Signature drawing animation
                    SignatureStrokeShape()
                        .trim(from: 0, to: signatureProgress)
                        .stroke(
                            Color(hex: "#1a56d6"),
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 150, height: 52)
                        .offset(x: 20, y: 88)
                        .opacity(signatureOpacity)

                    // Stamp impact ripple
                    Circle()
                        .stroke(Color.red.opacity(0.45), lineWidth: 3)
                        .frame(width: 90, height: 90)
                        .scaleEffect(impactScale)
                        .opacity(impactOpacity)
                        .offset(x: -58, y: 72)

                    // Animated stamp
                    stampView
                        .offset(x: -58, y: 72 + stampOffset)
                        .scaleEffect(stampScale)
                        .rotationEffect(.degrees(stampRotation))
                        .opacity(stampOpacity)
                }
                .frame(height: 300)

                VStack(spacing: 8) {
                    Image("LaunchLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .scaleEffect(logoScale)
                        .opacity(logoOpacity)

                    Text("DocuTranslate")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)

                    Text("Scan • Translate • Sign")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.78))
                }
                .opacity(titleOpacity)
                .offset(y: titleOffset)

                Spacer()
                Spacer()
            }
        }
        .opacity(exitOpacity)
        .onAppear { runAnimationSequence() }
    }

    private var documentLines: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(.systemGray4))
                .frame(width: 120, height: 8)
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(.systemGray5))
                    .frame(width: CGFloat(160 - i * 12), height: 6)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 220, height: 280, alignment: .topLeading)
    }

    private var stampView: some View {
        ZStack {
            Circle()
                .stroke(Color.red, lineWidth: 3)
                .background(Circle().fill(Color.red.opacity(0.08)))
            Circle()
                .stroke(Color.red.opacity(0.55), lineWidth: 1.5)
                .padding(8)
            Text("APPROVED")
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
        }
        .frame(width: 74, height: 74)
    }

    private func runAnimationSequence() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
            logoScale = 1
            logoOpacity = 1
        }

        withAnimation(.easeOut(duration: 0.45).delay(0.15)) {
            docOpacity = 1
            docOffset = 0
        }

        withAnimation(.easeIn(duration: 0.2).delay(0.55)) {
            signatureOpacity = 1
        }

        withAnimation(.easeInOut(duration: 1.1).delay(0.65)) {
            signatureProgress = 1
        }

        withAnimation(.easeIn(duration: 0.15).delay(1.75)) {
            stampOpacity = 1
        }

        withAnimation(.spring(response: 0.38, dampingFraction: 0.55).delay(1.8)) {
            stampOffset = 0
            stampScale = 1
            stampRotation = -12
        }

        withAnimation(.easeOut(duration: 0.35).delay(2.05)) {
            impactScale = 1.4
            impactOpacity = 0.8
        }

        withAnimation(.easeOut(duration: 0.25).delay(2.35)) {
            impactOpacity = 0
        }

        withAnimation(.easeOut(duration: 0.5).delay(2.15)) {
            titleOpacity = 1
            titleOffset = 0
        }

        withAnimation(.easeInOut(duration: 0.35).delay(3.1)) {
            exitOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.45) {
            onFinish()
        }
    }
}

// MARK: - Animated signature stroke

private struct SignatureStrokeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        path.move(to: CGPoint(x: w * 0.04, y: h * 0.62))
        path.addCurve(
            to: CGPoint(x: w * 0.28, y: h * 0.38),
            control1: CGPoint(x: w * 0.08, y: h * 0.18),
            control2: CGPoint(x: w * 0.18, y: h * 0.52)
        )
        path.addCurve(
            to: CGPoint(x: w * 0.48, y: h * 0.58),
            control1: CGPoint(x: w * 0.36, y: h * 0.26),
            control2: CGPoint(x: w * 0.42, y: h * 0.72)
        )
        path.addCurve(
            to: CGPoint(x: w * 0.72, y: h * 0.34),
            control1: CGPoint(x: w * 0.56, y: h * 0.40),
            control2: CGPoint(x: w * 0.62, y: h * 0.22)
        )
        path.addCurve(
            to: CGPoint(x: w * 0.96, y: h * 0.52),
            control1: CGPoint(x: w * 0.84, y: h * 0.48),
            control2: CGPoint(x: w * 0.90, y: h * 0.58)
        )
        return path
    }
}

import SwiftUI

/// SwiftUIのアニメーション機構（withAnimation/.animation(value:)）は通常View修飾子の
/// パラメータを対象にするため、Canvas描画クロージャの中で直接使っている生の値は
/// そのままでは補間されない。この透明ビューはanimatableDataとしてvalueを持たせることで
/// SwiftUIのアニメーションエンジンに毎フレームの中間値を計算させ、onChangeで
/// 呼び出し元へ橋渡しする（Canvasアニメーションの定番手法）。
///
/// 以前はCGFloat用（HandleScaleAnimator）とAnimatablePair<Double,Double>用
/// （ViewportAnimator）でほぼ同じ橋渡しコードが重複していたため、
/// VectorArithmeticでジェネリック化して1つにまとめた。
struct CanvasValueAnimator<Value: VectorArithmetic>: View, Animatable {
    var value: Value
    let onChange: (Value) -> Void

    var animatableData: Value {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Color.clear
            .onAppear { onChange(value) }
            .onChange(of: value) { _, newValue in onChange(newValue) }
    }
}

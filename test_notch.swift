import SwiftUI

struct TestNotchView: View {
    var body: some View {
        ZStack(alignment: .top) {
            NotchShape()
                .fill(Color.black)
                .frame(width: 240, height: 34)
            Text("100%")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .background(Color.red) // Debug background
                .padding(.top, 4)
        }
    }
}

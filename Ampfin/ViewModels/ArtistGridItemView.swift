import SwiftUI

struct ArtistGridItemView: View {
    let artist: ArtistItem
    let artworkURL: URL?
    
    var body: some View {
        VStack {
            if let url = artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(width: 120, height: 120)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 120, height: 120)
            }
            Text(artist.name)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 140)
        .padding(8)
    }
}

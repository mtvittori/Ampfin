// In Views/Shared/CachedAsyncImage.swift
import SwiftUI

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let scale: CGFloat
    private let transaction: Transaction
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var cachedImage: Image?

    init(
        url: URL?,
        scale: CGFloat = 1,
        transaction: Transaction = Transaction(),
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.scale = scale
        self.transaction = transaction
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        if let cachedImage = cachedImage {
            // Se abbiamo un'immagine in cache, la mostriamo subito
            content(cachedImage)
        } else if let url = url {
            // Altrimenti, usiamo la logica di AsyncImage
            AsyncImage(
                url: url,
                scale: scale,
                transaction: transaction
            ) { phase in
                switch phase {
                case .success(let image):
                    // Quando AsyncImage ha successo, salviamo l'immagine in cache
                    // e la mostriamo
                    let _ = cacheImage(from: image, for: url)
                    content(image)
                case .failure:
                    // Se fallisce, mostriamo il placeholder
                    placeholder()
                case .empty:
                    // Mentre carica, mostriamo il placeholder
                    placeholder()
                @unknown default:
                    placeholder()
                }
            }
            .onAppear {
                // Quando la vista appare, controlliamo subito se l'immagine è già in cache
                checkCache(for: url)
            }
        } else {
            placeholder()
        }
    }

    private func checkCache(for url: URL) {
        let key = ImageCacheService.shared.key(for: url)
        if let nsImage = ImageCacheService.shared.getImage(forKey: key) {
            // Se troviamo l'immagine (NSImage), la convertiamo in una Image di SwiftUI
            self.cachedImage = Image(nsImage: nsImage)
        }
    }
    
    // Per salvare l'immagine, dobbiamo renderizzarla in un NSImage per poterla salvare
    @MainActor
    private func cacheImage(from image: Image, for url: URL) -> some View {
        // Questa è la parte più complessa: renderizzare una SwiftUI Image in un'immagine concreta
        let key = ImageCacheService.shared.key(for: url)
        let renderer = ImageRenderer(content: image)
        
        // La dimensione qui è indicativa, renderer si adatta al contenuto
        renderer.proposedSize = .init(width: 300, height: 300)
        
        if let nsImage = renderer.nsImage {
            ImageCacheService.shared.setImage(nsImage, forKey: key)
        }
        
        // Ritorniamo una vista vuota perché questo modificatore non deve disegnare nulla
        return EmptyView()
    }
}

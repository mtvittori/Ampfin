// In Services/ImageCacheService.swift
import Foundation
import AppKit // Usiamo NSImage per macOS

class ImageCacheService {
    // Singleton per un accesso facile e globale
    static let shared = ImageCacheService()
    
    // Cache in memoria: veloce ma volatile
    private let memoryCache = NSCache<NSString, NSImage>()
    
    // Cache su disco: più lenta ma persistente
    private let fileManager = FileManager.default
    private let diskCachePath: URL
    
    private init() {
        // Creiamo una cartella dedicata nella directory di cache dell'utente
        if let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            self.diskCachePath = cacheDirectory.appendingPathComponent("ImageCache")
            
            // Creiamo la cartella se non esiste
            if !fileManager.fileExists(atPath: self.diskCachePath.path) {
                try? fileManager.createDirectory(at: self.diskCachePath, withIntermediateDirectories: true, attributes: nil)
            }
        } else {
            // Fallback nel caso non si possa accedere alla directory di cache
            self.diskCachePath = URL(fileURLWithPath: "")
        }
        
        // Impostiamo un limite per la cache in memoria per non usare troppa RAM
        memoryCache.countLimit = 100 // Manterrà in memoria le ultime 100 immagini
    }
    
    // Funzione per ottenere un'immagine
    func getImage(forKey key: String) -> NSImage? {
        // 1. Prova a prenderla dalla cache in memoria (velocissimo)
        if let cachedImage = memoryCache.object(forKey: key as NSString) {
            return cachedImage
        }
        
        // 2. Se non c'è, prova a prenderla dalla cache su disco
        let fileURL = diskCachePath.appendingPathComponent(key)
        if let data = try? Data(contentsOf: fileURL), let image = NSImage(data: data) {
            // Se la troviamo su disco, la mettiamo anche in memoria per accessi futuri più veloci
            memoryCache.setObject(image, forKey: key as NSString)
            return image
        }
        
        // 3. Se non si trova da nessuna parte, ritorna nil
        return nil
    }
    
    // Funzione per salvare un'immagine
    func setImage(_ image: NSImage, forKey key: String) {
        // 1. Salva in memoria
        memoryCache.setObject(image, forKey: key as NSString)
        
        // 2. Salva su disco in background per non bloccare l'UI
        DispatchQueue.global(qos: .background).async {
            guard let data = image.tiffRepresentation else { return }
            let fileURL = self.diskCachePath.appendingPathComponent(key)
            try? data.write(to: fileURL)
        }
    }
    
    // Funzione helper per generare una chiave unica dall'URL
    func key(for url: URL) -> String {
        // Usiamo un hash del path dell'URL per creare un nome file sicuro e unico
        return url.path.data(using: .utf8)?.base64EncodedString() ?? url.absoluteString
    }
}

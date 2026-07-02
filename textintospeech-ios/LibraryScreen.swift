import SwiftUI
import UniformTypeIdentifiers

/// The **Books** tab: the library grid with a continue-listening card; long-press a cover to
/// remove a book.
struct LibraryScreen: View {
    @Environment(\.theme) private var theme
    @ObservedObject var vm: LibraryViewModel
    @ObservedObject var repo: BookRepository
    let onOpenBook: (String) -> Void
    let onOpenSettings: () -> Void

    @State private var showImporter = false
    @State private var pendingDelete: Book?

    static let importableTypes: [UTType] = {
        var types: [UTType] = [.epub, .pdf, .rtf, .plainText, .utf8PlainText, .text]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        return types
    }()

    var body: some View {
        VStack(spacing: 0) {
            header

            if repo.books.isEmpty {
                emptyLibrary
            } else {
                grid
            }
        }
        .background(theme.surface.ignoresSafeArea())
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importableTypes) { result in
            if case .success(let url) = result { vm.importBook(pickedURL: url) }
        }
        .alert(
            "Couldn't add this book",
            isPresented: Binding(get: { vm.importState.error != nil }, set: { if !$0 { vm.dismissImportError() } })
        ) {
            Button("OK") { vm.dismissImportError() }
        } message: {
            Text(vm.importState.error ?? "")
        }
        .alert(
            "Remove this book?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { book in
            Button("Remove", role: .destructive) {
                vm.deleteBook(book)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { book in
            Text("“\(book.title)” will be removed from your library.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Read Aloud")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.primary)
                Text("Your library")
                    .font(.caption)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if vm.importState.busy {
                ProgressView().padding(.trailing, 8)
            }
            Button { showImporter = true } label: {
                Image(systemName: "plus")
                    .foregroundStyle(theme.primary)
                    .frame(width: 40, height: 40)
            }
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 40, height: 40)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.top, 12)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(theme.primary)
            Text("No books yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.onSurface)
                .padding(.top, 16)
            Text("Add an EPUB, PDF or text book and listen to it chapter by chapter. Tip: DRM-free EPUB works best. Copy-protected Kindle files can't be opened by any third-party app.")
                .font(.subheadline)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Button { showImporter = true } label: {
                Label("Add book", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(theme.secondaryContainer))
                    .foregroundStyle(theme.onSecondaryContainer)
            }
            .buttonStyle(.plain)
            .disabled(vm.importState.busy)
            .padding(.top, 20)
            Spacer()
        }
        .padding(32)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                alignment: .leading, spacing: 14
            ) {
                let recent = repo.books.first { (0.001...0.999).contains($0.progress) }
                if let recent {
                    Section {
                        EmptyView()
                    } header: {
                        ContinueListeningCard(book: recent, coverURL: repo.coverURL(for: recent)) {
                            onOpenBook(recent.id)
                        }
                    }
                }
                Section {
                    ForEach(repo.books) { book in
                        BookCell(book: book, coverURL: repo.coverURL(for: book))
                            .onTapGesture { onOpenBook(book.id) }
                            .onLongPressGesture { pendingDelete = book }
                    }
                } header: {
                    Text("All books")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, recent != nil ? 8 : 0)
                }
            }
            .padding(16)
        }
    }
}

private struct ContinueListeningCard: View {
    @Environment(\.theme) private var theme
    let book: Book
    let coverURL: URL?
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: 14) {
                BookCover(coverURL: coverURL)
                    .frame(width: 56, height: 80)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Continue listening")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.onPrimaryContainer)
                    Text(book.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.onPrimaryContainer)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("Chapter \(book.currentChapter + 1) of \(book.chapterCount)  ·  \(Int(book.progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(theme.onPrimaryContainer)
                    ProgressView(value: book.progress)
                        .tint(theme.primary)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 20).fill(theme.primaryContainer))
        }
        .buttonStyle(.plain)
    }
}

private struct BookCell: View {
    @Environment(\.theme) private var theme
    let book: Book
    let coverURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            BookCover(coverURL: coverURL)
                .aspectRatio(0.68, contentMode: .fit)
                .frame(maxWidth: .infinity)
            Text(book.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.onSurface)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if book.progress > 0 {
                Text("\(Int(book.progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct BookCover: View {
    @Environment(\.theme) private var theme
    let coverURL: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(theme.secondaryContainer)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "book.closed")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.onSecondaryContainer)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: coverURL) {
            guard let coverURL else { image = nil; return }
            image = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: coverURL.path)
            }.value
        }
    }
}

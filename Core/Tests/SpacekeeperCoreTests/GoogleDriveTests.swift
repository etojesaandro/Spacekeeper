import Foundation
import SpacekeeperCore
import Testing

private let client = "1234-abcd.apps.googleusercontent.com"

@Suite("Google sign-in")
struct GoogleSignInTests {
  private func signIn() -> GoogleSignIn {
    GoogleSignIn(
      client: client,
      proof: Proof(text: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
      state: "s1"
    )
  }

  @Test("returns to the client ID reversed, as Google prescribes for iOS")
  func scheme() {
    #expect(signIn().scheme() == "com.googleusercontent.apps.1234-abcd")
  }

  @Test("asks only for the files the app creates, with the hash of its secret")
  func page() throws {
    let items =
      URLComponents(url: signIn().page(), resolvingAgainstBaseURL: false)?.queryItems ?? []
    let facts = items.reduce(into: [String: String]()) { $0[$1.name] = $1.value ?? "" }

    #expect(signIn().page().host == "accounts.google.com")
    #expect(facts["scope"] == "https://www.googleapis.com/auth/drive.file")
    #expect(facts["response_type"] == "code")
    #expect(facts["redirect_uri"] == "com.googleusercontent.apps.1234-abcd:/oauth2redirect")
    // The example of RFC 7636, appendix B.
    #expect(facts["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(facts["code_challenge_method"] == "S256")
    #expect(facts["state"] == "s1")
  }

  @Test("takes the code from the address Google returns to")
  func granted() {
    let address = URL(
      string: "com.googleusercontent.apps.1234-abcd:/oauth2redirect?state=s1&code=4/xyz")!

    #expect(signIn().outcome(of: address) == .granted("4/xyz"))
  }

  @Test("refuses a return that belongs to another sign-in")
  func otherState() {
    let address = URL(
      string: "com.googleusercontent.apps.1234-abcd:/oauth2redirect?state=s2&code=4/xyz")!

    #expect(
      signIn().outcome(of: address)
        == .refused("Google returned to a sign-in that was not this one"))
  }

  @Test("tells when the user did not grant access")
  func denied() {
    let address = URL(
      string: "com.googleusercontent.apps.1234-abcd:/oauth2redirect?state=s1&error=access_denied"
    )!

    #expect(signIn().outcome(of: address) == .refused("Access to Google Drive was not granted"))
  }

  @Test("lets addresses of other schemes pass")
  func elsewhere() {
    #expect(signIn().outcome(of: URL(string: "https://accounts.google.com/signin")!) == .elsewhere)
  }

  @Test("makes up a fresh secret and state for every sign-in")
  func freshProof() {
    let first = GoogleSignIn(client: client).page().query ?? ""
    let second = GoogleSignIn(client: client).page().query ?? ""

    #expect(first != second)
  }

  @Test("trades the code and the secret for tokens that expire a minute early")
  func grant() async throws {
    let google = FakeGoogle()

    let grant = try await signIn().grant(for: "4/xyz", through: google.wire())

    let form = String(decoding: google.requests()[0].body, as: UTF8.self)
    #expect(form.contains("code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
    #expect(form.contains("grant_type=authorization_code"))
    #expect(form.contains("code=4/xyz") || form.contains("code=4%2Fxyz"))
    #expect(grant.access == "access1")
    #expect(grant.refresh == "lasting")
    #expect(grant.expiry.timeIntervalSinceNow > 3400 && grant.expiry.timeIntervalSinceNow < 3541)
  }

  @Test("keeps the refresh token when a renewal answers without one")
  func renewal() async throws {
    let google = FakeGoogle()

    let grant = try await GoogleTokens(client: client, wire: google.wire()).renewed("lasting")

    #expect(grant.refresh == "lasting")
    #expect(grant.access == "access1")
  }

  @Test("tells that the user withdrew access when Google calls the grant invalid")
  func withdrawn() async throws {
    let wire = ArrangedWire(Response(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)))

    let refusal = await #expect(throws: GoogleRefusal.self) {
      try await GoogleTokens(client: client, wire: wire).renewed("lasting")
    }

    #expect(refusal?.signedOut() == true)
  }
}

@Suite("Access token of whoever is signed in to Google")
struct GoogleBearerTests {
  private func bearer(_ google: FakeGoogle, _ refresh: KeptRefresh, _ clock: HandClock)
    -> GoogleBearer
  {
    GoogleBearer(
      tokens: GoogleTokens(client: client, wire: google.wire(), now: { clock.now() }),
      refresh: refresh,
      now: { clock.now() }
    )
  }

  @Test("buys a token once and uses it until it expires")
  func reused() async throws {
    let (google, clock) = (FakeGoogle(), HandClock())
    let bearer = bearer(google, KeptRefresh("lasting"), clock)

    let first = try await bearer.token()
    clock.pass(3000)
    let second = try await bearer.token()
    clock.pass(600)
    let third = try await bearer.token()

    #expect(first == "access1")
    #expect(second == "access1")
    #expect(third == "access2")
  }

  @Test("buys a new token when another account is signed in")
  func otherAccount() async throws {
    let (google, clock, refresh) = (FakeGoogle(), HandClock(), KeptRefresh("lasting"))
    let bearer = bearer(google, refresh, clock)

    _ = try await bearer.token()
    refresh.change(to: "other")

    #expect(try await bearer.token() == "access2")
  }

  @Test("buys a new token after Drive refused the one it had")
  func spoiled() async throws {
    let (google, clock) = (FakeGoogle(), HandClock())
    let bearer = bearer(google, KeptRefresh("lasting"), clock)

    _ = try await bearer.token()
    await bearer.spoiled()

    #expect(try await bearer.token() == "access2")
  }
}

@Suite("Google Drive as a place to keep files")
struct GoogleDriveTests {
  private func drive(_ google: FakeGoogle) -> GoogleDrive {
    GoogleDrive(
      api: GoogleApi(
        bearer: GoogleBearer(
          tokens: GoogleTokens(client: client, wire: google.wire()),
          refresh: KeptRefresh("lasting")
        ),
        wire: google.wire()
      )
    )
  }

  private func file(_ text: String) throws -> URL {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("spacekeeper-\(UUID().uuidString)")
    try Data(text.utf8).write(to: file)
    return file
  }

  @Test("opens an upload session in folders by year and month, made where missing")
  func door() async throws {
    let google = FakeGoogle()

    let door = try await drive(google).door(for: "2024/05/a.HEIC", bytes: 5)

    #expect(google.tree() == ["2024/", "2024/05/"])
    #expect(door.method == "PUT")
    #expect(door.headers["Authorization"] == nil)
    #expect(door.url.absoluteString.contains("upload_id="))
  }

  @Test("keeps a file and reports the fingerprint Drive records")
  func kept() async throws {
    let google = FakeGoogle()
    let source = try file("hello")
    defer { try? FileManager.default.removeItem(at: source) }

    let print = try await drive(google).kept(source, as: "2024/05/a.HEIC")

    #expect(print == Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592"))
    #expect(google.tree() == ["2024/", "2024/05/", "2024/05/a.HEIC"])
  }

  @Test("replaces a file sent again under the same name instead of keeping two")
  func replaced() async throws {
    let google = FakeGoogle()
    let first = try file("first")
    let second = try file("second!")
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    let drive = drive(google)

    _ = try await drive.kept(first, as: "2024/05/a.HEIC")
    let print = try await drive.kept(second, as: "2024/05/a.HEIC")

    #expect(google.tree() == ["2024/", "2024/05/", "2024/05/a.HEIC"])
    #expect(print == Fingerprint(bytes: 7, md5: Md5Of(Data("second!".utf8)).value()))
  }

  @Test("finds folders once and remembers them for the next files")
  func remembered() async throws {
    let google = FakeGoogle()
    let drive = drive(google)

    _ = try await drive.door(for: "2024/05/a.HEIC", bytes: 5)
    let before = google.requests().count
    _ = try await drive.door(for: "2024/05/b.HEIC", bytes: 5)

    // A search for a file of that name and the session; no folder is looked for again.
    #expect(google.requests().count - before == 2)
  }

  @Test("holds nothing for a name in a folder that is not there, and makes no folder for it")
  func nothingShelved() async throws {
    let google = FakeGoogle()

    let prints = try await drive(google).shelved("2024/05/a.HEIC")

    #expect(prints.isEmpty)
    #expect(google.tree().isEmpty)
  }

  @Test("gives a kept file the moment its original was made as its own date")
  func dated() async throws {
    let google = FakeGoogle()
    google.put("2024/05/a.HEIC", Data("hello".utf8))

    try await drive(google).dated("2024/05/a.HEIC", at: Date(timeIntervalSince1970: 1_715_000_000))

    #expect(google.entry("2024/05/a.HEIC").first?.modified == "2024-05-06T12:53:20.000Z")
  }

  @Test("cannot date a file Drive does not hold")
  func datedMissing() async throws {
    let google = FakeGoogle()

    await #expect(throws: MissingOnDrive.self) {
      try await drive(google).dated("2024/05/a.HEIC", at: Date())
    }
  }

  @Test("lists the folders and files of a folder, with their dates and pictures")
  func shelf() async throws {
    let google = FakeGoogle()
    google.put("2024/05/b.HEIC", Data("bb".utf8), modified: "2024-05-06T07:08:09.000Z")
    google.put("2024/05/a.MOV", Data("a".utf8))
    google.put("2024/06/c.HEIC", Data("c".utf8))

    let top = try await drive(google).shelf("")
    let may = try await drive(google).shelf("2024/05")

    #expect(top.folders() == ["2024"])
    #expect(may.folders().isEmpty)
    let files = may.originals().map { $0.leading() }
    #expect(files.map { $0.id } == ["2024/05/a.MOV", "2024/05/b.HEIC"])
    #expect(files[1].weight() == 2)
  }

  @Test("lists every page of a folder with many files")
  func pages() async throws {
    let google = FakeGoogle(pageSize: 2)
    for name in ["a", "b", "c", "d", "e"] {
      google.put("2024/05/\(name).HEIC", Data(name.utf8))
    }

    let shelf = try await drive(google).shelf("2024/05")

    #expect(shelf.originals().count == 5)
  }

  @Test("lists nothing for a folder that is not there")
  func emptyShelf() async throws {
    let shelf = try await drive(FakeGoogle()).shelf("2030")

    #expect(shelf.folders().isEmpty)
    #expect(shelf.originals().isEmpty)
  }

  @Test("asks for a picture big enough to fill a screen")
  func picture() async throws {
    let google = FakeGoogle()
    google.put("2024/05/a.HEIC", Data("hello".utf8))
    let drive = drive(google)
    let file = try await drive.shelf("2024/05").originals()[0].leading()

    let picture = try await drive.picture(of: file)

    #expect(String(decoding: picture, as: UTF8.self).hasSuffix("=s1600"))
  }

  @Test("fetches the content of a kept file back")
  func fetched() async throws {
    let google = FakeGoogle()
    google.put("2024/05/a.HEIC", Data("hello".utf8))
    let drive = drive(google)
    let file = try await drive.shelf("2024/05").originals()[0].leading()
    let place = FileManager.default.temporaryDirectory
      .appendingPathComponent("spacekeeper-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: place) }

    try await drive.fetched(file, into: place)

    #expect(try String(contentsOf: place, encoding: .utf8) == "hello")
  }

  @Test("finds names with quotes and backslashes in them")
  func quoted() async throws {
    let google = FakeGoogle()
    google.put("2024/05/it's a \\ file.JPG", Data("x".utf8))

    let prints = try await drive(google).shelved("2024/05/it's a \\ file.JPG")

    #expect(prints.count == 1)
  }

  @Test("buys a new token and asks again when Drive refuses the one it had")
  func renewedOnRefusal() async throws {
    let google = FakeGoogle()
    let drive = drive(google)
    _ = try await drive.shelved("2024/05/a.HEIC")

    google.revoke()
    _ = try await drive.shelved("2024/05/a.HEIC")

    #expect(google.tokens() == 2)
  }

  @Test("sends the token for pictures only to Google's own hosts")
  func foreignPicture() async throws {
    let google = FakeGoogle()
    let drive = drive(google)
    let file = KeptFile(
      path: "2024/05/a.HEIC",
      bytes: 1,
      print: Fingerprint(bytes: 1, md5: ""),
      made: [],
      preview: [URL(string: "https://example.com/a=s220")!]
    )

    _ = try? await drive.thumbnail(of: file)

    let asked = google.requests().last
    #expect(asked?.url.host == "example.com")
    #expect(asked?.headers["Authorization"] == nil)
  }
}

/// A wire that answers every request alike.
struct ArrangedWire: Wire {
  private let answer: Response

  init(_ answer: Response) {
    self.answer = answer
  }

  func response(to request: Request) async throws -> Response {
    answer
  }

  func response(to request: Request, sending file: URL) async throws -> Response {
    answer
  }

  func response(to request: Request, saving file: URL) async throws -> Response {
    answer
  }
}

@Suite("Space left on Google Drive, checked before an upload")
struct WithinDriveQuotaTests {
  private func depot(_ google: FakeGoogle) -> WithinDriveQuota {
    let api = GoogleApi(
      bearer: GoogleBearer(
        tokens: GoogleTokens(client: client, wire: google.wire()),
        refresh: KeptRefresh("lasting")
      ),
      wire: google.wire()
    )
    return WithinDriveQuota(GoogleDrive(api: api), api: api)
  }

  @Test("refuses a file larger than the space left, before opening an upload")
  func full() async throws {
    let google = FakeGoogle()
    google.quota(status: 200, body: #"{"storageQuota":{"limit":"100","usage":"95"}}"#)

    let refusal = await #expect(throws: CloudFull.self) {
      try await depot(google).door(for: "2024/05/a.MOV", bytes: 6)
    }

    #expect(refusal?.description == "2024/05/a.MOV is 6 bytes, but this Google Drive has only 5 bytes free")
    #expect(google.tree().isEmpty)
  }

  @Test("opens an upload for a file that exactly fills the space left")
  func fits() async throws {
    let google = FakeGoogle()
    google.quota(status: 200, body: #"{"storageQuota":{"limit":"100","usage":"95"}}"#)

    let door = try await depot(google).door(for: "2024/05/a.MOV", bytes: 5)

    #expect(door.method == "PUT")
  }

  @Test("lets any file pass on an account without a limit")
  func unlimited() async throws {
    let google = FakeGoogle()
    google.quota(status: 200, body: #"{"storageQuota":{"usage":"999999"}}"#)

    let door = try await depot(google).door(for: "2024/05/a.MOV", bytes: 1 << 40)

    #expect(door.method == "PUT")
  }

  @Test("leaves the decision to the upload when Drive will not tell the quota")
  func untold() async throws {
    let google = FakeGoogle()
    google.quota(status: 403, body: #"{"error":{"code":403,"message":"insufficient scope"}}"#)

    let door = try await depot(google).door(for: "2024/05/a.MOV", bytes: 5)

    #expect(door.method == "PUT")
  }

  @Test("asks only for the quota's limit and usage")
  func fields() async throws {
    let google = FakeGoogle()

    _ = try await depot(google).door(for: "2024/05/a.MOV", bytes: 5)

    let asked = google.requests().first { $0.url.path == "/drive/v3/about" }
    #expect(asked?.url.query?.contains("fields=storageQuota") == true)
  }
}

@Suite("Refusals of Google that pass with time")
struct RateLimitTests {
  @Test(
    "asks again when Google says a user or the app asked too often",
    arguments: [
      #"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}"#,
      #"{"error":{"code":403,"errors":[{"reason":"rateLimitExceeded"}]}}"#,
    ]
  )
  func limited(body: String) async throws {
    let google = FakeGoogle()
    google.quota(status: 200, body: #"{"storageQuota":{"limit":"100","usage":"0"}}"#)
    let refusal = try await refused(google, status: 403, body: body)

    #expect(refusal.stands() == false)
  }

  @Test("takes a refusal for a full Drive as final")
  func storage() async throws {
    let refusal = try await refused(
      FakeGoogle(),
      status: 403,
      body: #"{"error":{"code":403,"errors":[{"reason":"storageQuotaExceeded"}]}}"#
    )

    #expect(refusal.stands() == true)
  }

  /// The refusal a kept file meets when Drive answers its upload this way.
  private func refused(_ google: FakeGoogle, status: Int, body: String) async throws -> any Verdict {
    let refused = RefusingWire(status: status, body: body)
    let drive = GoogleDrive(
      api: GoogleApi(
        bearer: GoogleBearer(
          tokens: GoogleTokens(client: client, wire: google.wire()),
          refresh: KeptRefresh("lasting")
        ),
        wire: refused
      )
    )
    do {
      _ = try await drive.door(for: "2024/05/a.MOV", bytes: 5)
    } catch let verdict as any Verdict {
      return verdict
    }
    throw NoVerdict()
  }
}

/// A network on which every request is refused the same way.
struct RefusingWire: Wire {
  private let status: Int
  private let body: String

  init(status: Int, body: String) {
    self.status = status
    self.body = body
  }

  func response(to request: Request) async throws -> Response {
    Response(status: status, body: Data(body.utf8))
  }

  func response(to request: Request, sending file: URL) async throws -> Response {
    Response(status: status, body: Data(body.utf8))
  }

  func response(to request: Request, saving file: URL) async throws -> Response {
    Response(status: status, body: Data())
  }
}

/// The code under test failed without a verdict.
struct NoVerdict: Error {}

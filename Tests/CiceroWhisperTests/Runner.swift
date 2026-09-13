import Testing

@main
struct CiceroWhisperTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}

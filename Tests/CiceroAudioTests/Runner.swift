import Testing

@main
struct CiceroAudioTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}

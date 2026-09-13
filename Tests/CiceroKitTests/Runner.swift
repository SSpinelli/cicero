import Testing

@main
struct CiceroKitTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}

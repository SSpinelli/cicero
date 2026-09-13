import Testing

@main
struct CiceroInputTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}

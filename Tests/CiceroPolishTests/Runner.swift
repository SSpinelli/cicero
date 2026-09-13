import Testing

@main
struct CiceroPolishTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}

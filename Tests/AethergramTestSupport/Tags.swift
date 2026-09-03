import Testing

/// Tag taxonomy for the suite. Each tag names the class of failure a test
/// catches, and the vocabulary stays this short on purpose: a tag nothing
/// applies is a category nobody is thinking in, and a tag naming this package
/// inside this package says nothing at all.
///
/// `.consent` is the one that marks a requirement rather than a behaviour.
///
/// Tags document at the suite header; they do not select. `--filter` is a
/// regex over `<test-target>.<test-case>`, so a `.tag(...)` filter matches
/// nothing and still exits 0. Select by target or by suite name.
public extension Tag {
    @Tag static var consent: Self
    @Tag static var persistence: Self
    @Tag static var wireFormat: Self
    @Tag static var lifecycle: Self
}

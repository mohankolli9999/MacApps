import Foundation
import ReclaimCore

@MainActor func runValidatorTests(_ t: Harness) {
    t.section("Validator")

    let artefact = Artefact(id: "ollama.models",
                            path: URL(fileURLWithPath: "/fixture/models"),
                            logicalBytes: 1000, reclaimableBytes: 1024, tier: .exact)

    let proven = ValidationResult.proven(
        Recipe(kind: .ollamaPull, command: "ollama pull llama3:8b"))
    let ok = applyValidation(artefact, proven)
    t.equal(ok.tier, .exact, "proven artefact keeps its tier")
    t.expect(ok.recipe != nil, "proven artefact gains a recipe")
    t.expect(ok.tier <= Tier.automaticCeiling, "proven artefact is actionable")

    let failed = ValidationResult.unproven(reason: "ollama daemon unreachable")
    let downgraded = applyValidation(artefact, failed)
    t.equal(downgraded.tier, .irreplaceable, "unproven artefact downgrades to irreplaceable")
    t.expect(downgraded.recipe == nil, "unproven artefact carries no recipe")
    t.expect(!(downgraded.tier <= Tier.automaticCeiling), "unproven artefact is not actionable")

    // A costly artefact that fails validation also downgrades — no exceptions.
    let costly = Artefact(id: "xcode.deriveddata", path: URL(fileURLWithPath: "/fixture/dd"),
                          logicalBytes: 1, reclaimableBytes: 1, tier: .costly)
    t.equal(applyValidation(costly, failed).tier, .irreplaceable,
            "costly artefact downgrades on failure too")

    t.section("Validator registry")
    func entry(_ validator: String, kind: Recipe.Kind? = nil, note: String? = nil) -> CatalogueEntry {
        CatalogueEntry(id: "x", displayName: "x", path: "/x", tier: .exact,
                       recipeKind: kind, validator: validator, restoreNote: note)
    }
    t.expect(ValidationRegistry.validator(for: entry("alwaysProven", kind: .npmCleanInstall)) != nil,
             "alwaysProven validator resolves")
    t.expect(ValidationRegistry.validator(for: entry("none")) != nil, "none validator resolves")
    t.expect(ValidationRegistry.validator(for: entry("ollama")) != nil, "ollama validator resolves")
    t.expect(ValidationRegistry.validator(for: entry("automatic", note: "Nothing to run.")) != nil,
             "automatic validator resolves when the catalogue supplies a note")

    // Without a note there is no instruction to give, so it must not resolve.
    t.expect(ValidationRegistry.validator(for: entry("automatic")) == nil,
             "automatic validator without a note resolves to nil")

    // An unrecognised validator name must not silently pass.
    t.expect(ValidationRegistry.validator(for: entry("bogus")) == nil,
             "unknown validator name resolves to nil, not a permissive default")
}

func runAsyncValidatorTests(_ t: Harness) async {
    await t.section("Validator behaviour")

    let artefact = Artefact(id: "npm.cache", path: URL(fileURLWithPath: "/fixture/npm"),
                            logicalBytes: 1, reclaimableBytes: 1, tier: .exact)

    let always = AlwaysProvenValidator(recipe: Recipe(kind: .npmCleanInstall, command: "npm ci"))
    if case .proven = await always.validate(artefact) {
        await t.expect(true, "AlwaysProvenValidator proves")
    } else {
        await t.expect(false, "AlwaysProvenValidator proves")
    }

    let never = NeverProvenValidator(reason: "no recipe exists")
    if case .unproven(let reason) = await never.validate(artefact) {
        await t.equal(reason, "no recipe exists", "NeverProvenValidator reports its reason")
    } else {
        await t.expect(false, "NeverProvenValidator refuses")
    }

    // A command validator whose command does not exist must be unproven.
    let missing = CommandValidator(executable: "/usr/bin/definitely-not-a-real-binary",
                                   arguments: [],
                                   recipe: Recipe(kind: .ollamaPull, command: "ollama pull x"))
    if case .unproven = await missing.validate(artefact) {
        await t.expect(true, "CommandValidator is unproven when the tool is absent")
    } else {
        await t.expect(false, "CommandValidator is unproven when the tool is absent")
    }

    // A command validator that succeeds must be proven.
    let present = CommandValidator(executable: "/bin/echo", arguments: ["ok"],
                                   recipe: Recipe(kind: .ollamaPull, command: "ollama pull x"))
    if case .proven = await present.validate(artefact) {
        await t.expect(true, "CommandValidator is proven when the command succeeds")
    } else {
        await t.expect(false, "CommandValidator is proven when the command succeeds")
    }
}

import Foundation

// MARK: - DealPrint

/// Whether, when, and how a deal advertises itself on a printed receipt.
///
/// This is about ADVERTISING, not pricing. Nothing here changes how `DealEngine` values a
/// basket, what a customer is charged, or whether a scanned coupon redeems — a deal with
/// no `print` config prices exactly the same as one that has it. It decides which deals
/// get put in front of a customer on paper, and in what words.
///
/// `nil` on `Deal` is the default and the safe state: every deal that exists today decodes
/// to `nil`, so nothing begins printing by surprise.
///
/// ## About the name `priority`
///
/// `Deal.priority` was REMOVED from this package in v0.2.0, and this is deliberately not a
/// reintroduction of it. That field was a tiebreaker dressed as a ranking dial: it only
/// separated two deals producing byte-identical savings on the same line, could never make
/// a smaller discount beat a bigger one, and managers were shown "Priority (higher wins)"
/// which is not what it did.
///
/// This one IS a ranking dial. When more deals match a sale than the store's cap allows,
/// this is the number that decides which are printed and which are not — a customer holds
/// one coupon rather than another because of it. The old name was wrong for the old field;
/// it is right for this one.
public struct DealPrint: Equatable, Sendable {
    /// When this deal is a candidate for the paper.
    public let trigger: DealPrintTrigger
    /// Rank when more deals match than the receipt's cap allows. Higher wins; ties break
    /// by deal `id` ascending so the order is total and reproducible.
    public let priority: Int
    /// The offer, in the customer's words.
    ///
    /// `nil` means THIS DEAL DOES NOT PRINT — it is not an instruction to describe the
    /// rule automatically. The copy is written when the deal is authored, where a person
    /// reads it before it is stored, so the OFFER is never described automatically and
    /// `Deal.name` (an internal rule label like "Aug wknd scotch -5") can never reach a
    /// customer. (`CouponTerms` deriving the small print from enforced predicates is a
    /// different thing than dressing an internal label up as an offer — this ruling is
    /// about the headline, and it stands.)
    ///
    /// Same fail-closed shape as a missing `couponCode`: a coupon that cannot describe
    /// itself is not printed at all.
    public let headline: String?
    /// The owner's NOTE, appended after the derived terms clauses.
    ///
    /// The enforced small print — audience, scope, minimums, schedule window, channel,
    /// per-customer limit — is composed by `CouponTerms` from the deal's structured
    /// fields at coupon-assembly time and is never stored, so the paper only promises
    /// what the register enforces. This field is for the part rules cannot say ("See
    /// staff for details"), and it prints verbatim, last. Optional even when `headline`
    /// is set — "$5 OFF" needs no qualification.
    public let terms: String?

    public init(trigger: DealPrintTrigger, priority: Int,
                headline: String?, terms: String?) {
        self.trigger = trigger
        self.priority = priority
        self.headline = headline
        self.terms = terms
    }
}

// MARK: - DealPrintTrigger

/// What makes a deal a candidate for THIS sale's paper.
///
/// Evaluated against the CART at commit, not against a persisted sale: category matching
/// needs a category name per line, which is what the cart carries
/// (`DealEvaluation.categoryName`). Reading categories back off a written sale would be a
/// second, weaker source for a fact the register already has in hand.
///
/// Decode failure — a missing key, a wrong type, an unrecognized `type`, a required
/// sub-field absent — is handled by the CALLER (`Deal.init(from:)`) via `try?`, which is
/// what makes the whole `print` config fail CLOSED to `nil`. This type's own
/// `init(from:)` just throws normally on anything it cannot parse, matching `DealScope`.
public enum DealPrintTrigger: Equatable, Sendable {
    /// Every sale.
    case always
    /// Any line whose category is one of these NAMES — names, not ids, matching
    /// `DealScope.category`'s own O-2b ruling.
    case basketHasCategory(names: Set<String>)
    case basketHasProduct(ids: Set<String>)
    /// The sale's TOTAL — what the customer actually paid, after discounts — is at least
    /// this. The total rather than the subtotal, so the trigger means what an owner reads
    /// it to mean.
    case saleOver(Money)
}

// MARK: - Decodable

extension DealPrint: Decodable {
    private enum CodingKeys: String, CodingKey {
        case trigger, priority, headline, terms
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `trigger` is REQUIRED and throws: a print config with no trigger has no answer
        // to "when does this print", and the caller's `try?` turns that into "never",
        // which is the safe reading.
        trigger = try container.decode(DealPrintTrigger.self, forKey: .trigger)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        headline = try container.decodeIfPresent(String.self, forKey: .headline)
        terms = try container.decodeIfPresent(String.self, forKey: .terms)
    }
}

extension DealPrintTrigger: Decodable {
    private enum CodingKeys: String, CodingKey { case type, names, ids, amount }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "always":
            self = .always
        case "basketHasCategory":
            self = .basketHasCategory(names: Set(try container.decode([String].self, forKey: .names)))
        case "basketHasProduct":
            self = .basketHasProduct(ids: Set(try container.decode([String].self, forKey: .ids)))
        case "saleOver":
            // Dollars on the wire, like every other money field in this package.
            self = .saleOver(Money(dollars: try container.decode(Double.self, forKey: .amount)))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unrecognized print trigger type '\(type)'"
            )
        }
    }
}

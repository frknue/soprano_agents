import AppKit
@testable import SopranoAgentsCore
import Testing

struct OmpFormTests {
    /// The `ask` form that hung Soprano Agents (omp 19.1.1 sends it as one `form` request).
    private static let html = """
    <form>
      <p>Shipping Protection test on us.valkental.com (US only, $4.95).</p>
      <fieldset>
        <legend>1. Where the logic lives</legend>
        <label><input type="radio" name="build" value="ab_app_module" checked> New module in the AB INT app</label>
        <label><input type="radio" name="build" value="content_js"> Content test &amp; frozen js</label>
      </fieldset>
      <p>Which stores?</p>
      <label><input type="checkbox" name="stores" value="us" checked> US</label>
      <label><input type="checkbox" name="stores" value="uk"> UK</label>
      <label>Session lifetime (days) <input type="number" name="ttl_days" value="30" min="1"></label>
      <label for="notes">Notes</label>
      <textarea id="notes" name="notes">first line</textarea>
      <label>Store <select name="store"><option value="sqlite">SQLite</option><option value="redis" selected>Redis</option></select></label>
      <label><input type="checkbox" name="confirm" value="yes"> I checked the cart</label>
      <input type="hidden" name="token" value="abc">
    </form>
    """

    private static let form = OmpForm(html: html)!

    @Test func everyAnswerableControlBecomesOneQuestionInFormOrder() {
        let questions = Self.form.questions()

        #expect(questions.map(\.id) == ["build", "stores", "ttl_days", "notes", "store", "confirm"])
        #expect(questions[0].question == "Shipping Protection test on us.valkental.com (US only, $4.95).\n\n1. Where the logic lives")
        #expect(questions[0].options.map(\.label) == ["New module in the AB INT app", "Content test & frozen js"])
        #expect(!questions[0].allowsMultiple && questions[0].allowsOther && questions[0].initialSelection == ["New module in the AB INT app"])
        #expect(questions[1].question == "Which stores?" && questions[1].allowsMultiple && questions[1].initialSelection == ["US"])
        #expect(questions[2].question == "Session lifetime (days)" && questions[2].options.isEmpty && questions[2].initialText == "30")
        #expect(questions[3].question == "Notes" && questions[3].initialText == "first line")
        #expect(questions[4].question == "Store" && !questions[4].allowsOther && questions[4].initialSelection == ["Redis"])
        #expect(questions[5].options.map(\.label) == ["I checked the cart"] && !questions[5].allowsOther)
    }

    @Test func answersSubmitOptionValuesByNameLikeAnHTMLForm() {
        let data = Self.form.data(answers: [
            "build": ["Content test & frozen js"],
            "stores": ["US", "UK", "CA"],
            "ttl_days": ["14"],
            "notes": ["a", "b"],
            "store": ["SQLite"],
            "confirm": [],
        ])

        #expect(data == [
            "build": "content_js",
            "stores": ["us", "uk", "CA"],
            "ttl_days": .number(14),
            "notes": "a\nb",
            "store": "sqlite",
        ])
    }

    @Test func freeTextIsARadioGroupsOtherAnswerAndUnansweredFieldsKeepTheirStart() {
        let data = Self.form.data(answers: ["build": ["Something else"]])

        #expect(data["build"] == "Something else")
        #expect(data["stores"] == ["us"])
        #expect(data["ttl_days"] == .number(30))
        #expect(data["store"] == "redis")
        #expect(data["confirm"] == nil)
        #expect(data["token"] == nil)
    }

    @Test func aRequiredChoiceLeftEmptyFallsBackToItsCheckedOption() {
        let form = OmpForm(html: #"<form><p>Pick</p><label><input type="radio" name="a" value="x" required checked> X</label><label><input type="radio" name="a" value="y"> Y</label></form>"#)!

        #expect(form.data(answers: ["a": []]) == ["a": "x"])
    }

    @Test func aNumberJSONCannotCarryIsLeftOutLikeAnEmptyField() {
        #expect(Self.form.data(answers: ["ttl_days": ["nan"]])["ttl_days"] == nil)
        #expect(Self.form.data(answers: ["ttl_days": ["inf"]])["ttl_days"] == nil)
        #expect(Self.form.data(answers: ["ttl_days": ["12.5"]])["ttl_days"] == .number(12.5))
    }

    @Test func aGroupWithAnOptionLabelledOtherTakesNoExtraAnswer() {
        let form = OmpForm(html: #"<form><label><input type="radio" name="a" value="x"> X</label><label><input type="radio" name="a" value="o"> Other</label></form>"#)!

        #expect(!form.questions()[0].allowsOther)
        #expect(form.data(answers: ["a": ["free"]]).isEmpty)
    }

    @Test func aFormWithoutAnAnswerableControlIsNil() {
        #expect(OmpForm(html: #"<form><p>Only context</p><input type="hidden" name="t" value="1"></form>"#) == nil)
        #expect(OmpForm(html: "not html at all") == nil)
    }

    @Test func theFormRequestBecomesAUserInputRequestAndIsAnsweredWithData() {
        let request = OmpUIRequest(["type": "extension_ui_request", "id": "f1", "method": "form", "html": .string(Self.html)])!
        let questions = OmpEventMapper.userInput(request).questions

        #expect(request.method == .form && questions.count == 6)
        let frame = OmpSession.response(to: request, answers: ["build": ["New module in the AB INT app"]]).frame
        #expect(frame["type"] == "extension_ui_response" && frame["id"] == "f1")
        #expect(frame["data"]?["build"] == "ab_app_module" && frame["data"]?["store"] == "redis")
        #expect(OmpSession.response(to: request, answers: [:]).frame == ["type": "extension_ui_response", "id": "f1", "cancelled": true])
    }
}

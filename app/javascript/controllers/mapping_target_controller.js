import { Controller } from "@hotwired/stimulus"

// Inline-edit for the mapping grid. Each editable control (target typeahead,
// mapping-type/confidence selects, reviewed checkbox, notes) fires
// change->mapping-target#submit, which submits the per-row form the control is
// associated with (via the HTML5 form= attribute). The controller is mounted
// on the table so it sees change events from any descendant control.
export default class extends Controller {
  submit(event) {
    const el = event.currentTarget
    const form = el.form || el.closest("form")
    if (form) form.requestSubmit()
  }
}

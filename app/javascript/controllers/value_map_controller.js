import { Controller } from "@hotwired/stimulus"

// Auto-submits a per-source-value form in the picklist value-mapping sub-table
// when its target-enum select changes. The form targets the value-table Turbo
// Frame, so the response re-renders just the sub-table.
export default class extends Controller {
  submit(event) {
    const form = event.currentTarget.form || event.currentTarget.closest("form")
    if (form) form.requestSubmit()
  }
}

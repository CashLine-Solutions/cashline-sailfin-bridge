import { Controller } from "@hotwired/stimulus"

// Bulk-select for the grouping roll-up bar. Tracks which grouping checkboxes
// are ticked, drives the "select all shown" toggle, shows a live count, and
// disables the submit button until at least one grouping is selected.
//
// Markup contract:
//   <div data-controller="rollup">
//     <form id="rollup-form" ...>
//       <input type="checkbox" data-rollup-target="all"
//              data-action="change->rollup#toggleAll">
//       <span data-rollup-target="count">0</span>
//       <button data-rollup-target="submit">Roll up</button>
//     </form>
//     ...cards each with:
//       <input type="checkbox" data-rollup-target="checkbox"
//              data-action="change->rollup#update" form="rollup-form">
//   </div>
export default class extends Controller {
  static targets = ["checkbox", "all", "count", "submit"]

  connect() {
    this.update()
  }

  toggleAll() {
    this.checkboxTargets.forEach((c) => (c.checked = this.allTarget.checked))
    this.update()
  }

  update() {
    const total = this.checkboxTargets.length
    const selected = this.checkboxTargets.filter((c) => c.checked).length

    if (this.hasCountTarget) this.countTarget.textContent = selected
    if (this.hasSubmitTarget) this.submitTarget.disabled = selected === 0
    if (this.hasAllTarget) {
      this.allTarget.checked = selected > 0 && selected === total
      this.allTarget.indeterminate = selected > 0 && selected < total
    }
  }
}

import { Controller } from "@hotwired/stimulus"

// Inline row-expand for the /objects index. Each row's chevron button has a
// data-expandable-frame-id-value pointing at the detail row's id, and a
// data-expandable-frame-url-value with the URL Turbo should fetch on first
// expand. Subsequent toggles reuse the cached frame contents.
export default class extends Controller {
  static values = {
    frameId: String,
    frameUrl: String,
    expandedClass: { type: String, default: "expanded" }
  }
  static targets = ["chevron"]

  toggle(event) {
    event.preventDefault()
    const detailRow = document.getElementById(`${this.frameIdValue}-row`)
    const frame = document.getElementById(this.frameIdValue)
    if (!detailRow || !frame) return

    const isOpen = !detailRow.classList.contains("hidden")

    if (isOpen) {
      detailRow.classList.add("hidden")
      this.#setChevron("▸")
    } else {
      detailRow.classList.remove("hidden")
      this.#setChevron("▾")
      // Lazy-load on first open. Subsequent opens skip the fetch because
      // src is already set and Turbo caches the frame's contents.
      if (!frame.hasAttribute("src")) {
        frame.setAttribute("src", this.frameUrlValue)
      }
    }
  }

  #setChevron(text) {
    if (this.hasChevronTarget) this.chevronTarget.textContent = text
  }
}

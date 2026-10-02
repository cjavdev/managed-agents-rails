import { Controller } from "@hotwired/stimulus"

// Keeps the transcript scrolled to the newest event and makes the composer
// behave like a chat box.
export default class extends Controller {
  static targets = ["scroll", "form", "input"]

  connect() {
    this.observer = new MutationObserver(() => this.scrollToEnd())
    this.observer.observe(this.scrollTarget, { childList: true, subtree: true })
    this.scrollToEnd()
  }

  disconnect() {
    this.observer?.disconnect()
  }

  // Enter sends, Shift+Enter adds a line.
  submitOnEnter(event) {
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return

    event.preventDefault()
    if (this.inputTarget.value.trim() !== "") this.formTarget.requestSubmit()
  }

  // Keep what was typed when the send failed.
  reset(event) {
    if (event.detail.success) this.formTarget.reset()
  }

  scrollToEnd() {
    this.scrollTarget.scrollTop = this.scrollTarget.scrollHeight
  }
}

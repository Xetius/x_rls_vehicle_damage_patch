// Colours damaged parts in RLS Part Customization.
//
// The Lua side (xRlsVehicleDamagePatch) ends a damaged slot's name with invisible marker
// characters. This script finds those names anywhere in the UI and:
//   damaged part   "Hood ⁣0% ⁤broken"        -> "Hood" in red, then a small "0%"
//   parent of one  "Body ⁢⁤2 damaged inside" -> "Body" in yellow
// The words after U+2064 are only there for the slot search, so they're hidden.
// RLS's .vue files are left alone: the script only changes the text Vue already put on the page,
// and puts it right again whenever Vue rewrites it.
'use strict'

const MARK_PART = '⁣'
const MARK_INSIDE = '⁢'
const MARK_HIDE = '⁤'
const MARKS = /[⁢⁣]/
const CLASS_PART = 'xvd-damaged'
const CLASS_INSIDE = 'xvd-inside'
const CLASS_EXTRA = 'xvd-extra'

const CSS = `
.${CLASS_PART} { color: #ff5c5c !important; }
.${CLASS_INSIDE} { color: #ffc940 !important; }
.${CLASS_EXTRA} { font-size: 0.72em; margin-left: 0.4em; color: #ff5c5c; opacity: 0.9; white-space: nowrap; }
`

function ensureStyle() {
  if (document.getElementById('xvd-style')) return
  const style = document.createElement('style')
  style.id = 'xvd-style'
  style.textContent = CSS
  document.head.appendChild(style)
}

// Undo this script's changes on an element whose text Vue has replaced.
function reset(el) {
  el.classList.remove(CLASS_PART, CLASS_INSIDE)
  for (const extra of el.querySelectorAll(':scope > .' + CLASS_EXTRA)) extra.remove()
  delete el.xvdShown
}

// ownWrite: the change is this script's own rewrite below, not Vue's.
function processText(node, ownWrite) {
  const el = node.parentElement
  if (!el || el.tagName === 'STYLE' || el.tagName === 'SCRIPT') return
  if (ownWrite) return
  const text = node.nodeValue || ''

  if (!MARKS.test(text)) {
    // Vue now shows a name without damage (part replaced in the cart, or repaired).
    if (el.xvdShown !== undefined) reset(el)
    return
  }

  reset(el)
  const visible = text.split(MARK_HIDE)[0]
  let name
  if (visible.includes(MARK_PART)) {
    const parts = visible.split(MARK_PART)
    name = parts[0].replace(/\s+$/, '')
    const percent = (parts[1] || '').trim()
    el.classList.add(CLASS_PART)
    if (percent) {
      const small = document.createElement('span')
      small.className = CLASS_EXTRA
      small.textContent = percent
      el.appendChild(small)
    }
  } else {
    name = visible.split(MARK_INSIDE)[0].replace(/\s+$/, '')
    el.classList.add(CLASS_INSIDE)
  }
  el.xvdShown = name
  node.nodeValue = name
}

function scan(root) {
  if (root.nodeType === Node.TEXT_NODE) {
    processText(root)
    return
  }
  if (root.nodeType !== Node.ELEMENT_NODE) return
  const text = root.textContent
  if (!text || !MARKS.test(text)) return
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
  const found = []
  while (walker.nextNode()) {
    if (MARKS.test(walker.currentNode.nodeValue || '')) found.push(walker.currentNode)
  }
  for (const node of found) processText(node)
}

function start() {
  if (window.xRlsVehicleDamagePatchObserver) return
  ensureStyle()
  const observer = new MutationObserver(mutations => {
    for (const mutation of mutations) {
      if (mutation.type === 'characterData') {
        // Our rewrite replaces marked text with the plain name; Vue's never starts from marked text
        // that we haven't already rewritten.
        const target = mutation.target
        const el = target.parentElement
        const ownWrite = MARKS.test(mutation.oldValue || '') && el && target.nodeValue === el.xvdShown
        processText(target, ownWrite)
      } else {
        for (const added of mutation.addedNodes) scan(added)
      }
    }
  })
  observer.observe(document.body, {childList: true, subtree: true, characterData: true, characterDataOldValue: true})
  window.xRlsVehicleDamagePatchObserver = observer
  scan(document.body)
}

if (document.body) start()
else document.addEventListener('DOMContentLoaded', start)

// BeamNG adds every ui/modModules folder to the Angular app by this name, so it has to exist.
export default angular.module('xRlsVehicleDamagePatch', [])

// Safari runs this JavaScript inside the page context before the
// "Copied Clipper" action extension loads. It captures document title,
// URL, and any text the user had selected at the moment of sharing, and
// passes them to the native extension so the compose sheet can pre-fill.
//
// The `ExtensionPreprocessingJS` global is the documented Safari API
// contract — do not rename. `run(arguments)` is invoked by Safari with
// `arguments.completionFunction` as the dispatch hook to native. Any JS
// error here will silently drop the payload, so keep it defensive.

var Action = function() {};

Action.prototype = {
    run: function(arguments) {
        try {
            var selection = "";
            if (window.getSelection) {
                var sel = window.getSelection();
                if (sel) { selection = sel.toString(); }
            }
            arguments.completionFunction({
                "title": document.title || "",
                "url": window.location.href || "",
                "selection": selection
            });
        } catch (e) {
            arguments.completionFunction({
                "title": "",
                "url": "",
                "selection": ""
            });
        }
    },
    finalize: function(arguments) {
        // No-op. The Clipper extension only reads from the page; it does
        // not inject any DOM changes that would need cleanup.
    }
};

var ExtensionPreprocessingJS = new Action;

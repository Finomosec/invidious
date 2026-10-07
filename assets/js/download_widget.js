'use strict';

(function () {
    var toggle = document.getElementById('download-overlay-toggle');
    if (!toggle) return;

    var overlay = document.querySelector('.download-overlay');

    overlay.querySelectorAll('.download-captions-select, .download-captions-filter').forEach(function (el) {
        el.hidden = false;
    });

    function caption_visible(checkbox) {
        return checkbox.parentElement.style.display !== 'none';
    }

    var video_id_input = overlay.querySelector('.download-tab-merged input[name="id"]');
    var prefetched_captions = {};

    function prefetch_caption(checkbox) {
        if (!video_id_input || !checkbox.checked || prefetched_captions[checkbox.value]) return;
        prefetched_captions[checkbox.value] = true;

        var body = new URLSearchParams();
        body.append('id', video_id_input.value);
        body.append('caption', checkbox.value);
        fetch('/download/merged/subtitle', { method: 'POST', body: body }).catch(function () {
            delete prefetched_captions[checkbox.value];
        });
    }

    function prefetch_checked_captions() {
        overlay.querySelectorAll('input[name="caption"]').forEach(prefetch_caption);
    }

    overlay.addEventListener('change', function (e) {
        if (e.target.name === 'caption') prefetch_caption(e.target);
    });

    overlay.addEventListener('click', function (e) {
        var selection = e.target.getAttribute('data-download-captions');
        if (!selection) return;

        overlay.querySelectorAll('input[name="caption"]').forEach(function (checkbox) {
            if (caption_visible(checkbox)) checkbox.checked = (selection === 'all');
        });
        prefetch_checked_captions();
    });

    var filter = overlay.querySelector('.download-captions-filter input');
    if (filter) {
        var caption_list = overlay.querySelector('.download-captions-list');
        var caption_labels = Array.prototype.slice.call(caption_list.children);

        var apply_filter = function () {
            var query = filter.value.trim().toLowerCase();

            caption_labels.forEach(function (label) {
                var checkbox = label.querySelector('input');
                var text = (label.textContent + ' ' + checkbox.dataset.language).toLowerCase();
                label.style.display = text.indexOf(query) === -1 ? 'none' : '';
            });

            caption_labels.filter(function (label) {
                return label.querySelector('input').checked;
            }).concat(caption_labels.filter(function (label) {
                return !label.querySelector('input').checked;
            })).forEach(function (label) {
                caption_list.appendChild(label);
            });
        };

        filter.addEventListener('input', apply_filter);

        filter.addEventListener('keydown', function (e) {
            if (e.key === 'Enter') e.preventDefault();
        });

        overlay.querySelector('.download-captions-filter button').addEventListener('click', function () {
            filter.value = '';
            apply_filter();
            filter.focus();
        });
    }

    addEventListener('keydown', function (e) {
        if (e.key === 'Escape' && toggle.checked) {
            toggle.checked = false;
            toggle.focus();
        }
    });

    toggle.addEventListener('change', function () {
        if (toggle.checked) {
            prefetch_checked_captions();

            var first_select = overlay.querySelector('select');
            if (first_select) first_select.focus();
        }
    });

    overlay.querySelectorAll('form').forEach(function (form) {
        form.addEventListener('submit', function () {
            toggle.checked = false;
        });
    });

    var video_select = document.getElementById('download_merged_video');
    var audio_select = document.getElementById('download_merged_audio');
    if (!video_select || !audio_select) return;

    var captions = overlay.querySelectorAll('input[name="caption"]');

    function select_closest(select, penalty) {
        var best = null;
        var best_penalty = Infinity;

        Array.prototype.forEach.call(select.options, function (option) {
            var p = penalty(option.dataset);
            if (p < best_penalty) {
                best = option;
                best_penalty = p;
            }
        });

        if (best) best.selected = true;
    }

    var saved_video = helpers.storage.get('download_video');
    if (saved_video) {
        select_closest(video_select, function (option) {
            return Math.abs(option.height - saved_video.height) * 1000 +
                (option.codec === saved_video.codec ? 0 : 100) +
                Math.abs(option.fps - saved_video.fps);
        });
    }

    var saved_audio = helpers.storage.get('download_audio');
    if (saved_audio) {
        select_closest(audio_select, function (option) {
            return (option.codec === saved_audio.codec ? 0 : 1e8) +
                Math.abs(option.bitrate - saved_audio.bitrate);
        });
    }

    var saved_captions = helpers.storage.get('download_captions');
    if (saved_captions) {
        captions.forEach(function (checkbox) {
            checkbox.checked = saved_captions.some(function (caption) {
                return caption.language === checkbox.dataset.language &&
                    caption.auto === checkbox.dataset.auto;
            });
        });
    }

    video_select.form.addEventListener('submit', function () {
        var video = video_select.selectedOptions[0].dataset;
        var audio = audio_select.selectedOptions[0].dataset;

        helpers.storage.set('download_video', {
            height: Number(video.height),
            fps: Number(video.fps),
            codec: video.codec
        });

        helpers.storage.set('download_audio', {
            bitrate: Number(audio.bitrate),
            codec: audio.codec
        });

        if (captions.length === 0) return;

        helpers.storage.set('download_captions', Array.prototype.filter.call(captions, function (checkbox) {
            return checkbox.checked;
        }).map(function (checkbox) {
            return { language: checkbox.dataset.language, auto: checkbox.dataset.auto };
        }));
    });
})();

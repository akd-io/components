# Re-export of Bazel rules with repository-wide defaults

load("@npm_angular_bazel//:index.bzl", _ng_module = "ng_module", _ng_package = "ng_package")
load("@npm_bazel_jasmine//:index.bzl", _jasmine_node_test = "jasmine_node_test")
load("@npm_bazel_karma//:defs.bzl", _karma_web_test_suite = "karma_web_test_suite")
load("@npm_bazel_protractor//:index.bzl", _protractor_web_test_suite = "protractor_web_test_suite")
load("@npm_bazel_typescript//:defs.bzl", _ts_library = "ts_library")
load("//:packages.bzl", "ANGULAR_LIBRARY_UMDS", "VERSION_PLACEHOLDER_REPLACEMENTS")
load("//:rollup-globals.bzl", "ROLLUP_GLOBALS")
load("//tools/markdown-to-html:index.bzl", _markdown_to_html = "markdown_to_html")

_DEFAULT_TSCONFIG_BUILD = "//src:bazel-tsconfig-build.json"
_DEFAULT_TSCONFIG_TEST = "//src:tsconfig-test"

# Whether Angular type checking should be enabled or not. Enabled by
# default but will be overwritten when running snapshots tests with Ivy
# since type-checking is not complete yet. See FW-1004.
_ENABLE_NG_TYPE_CHECKING = True

# Re-exports to simplify build file load statements
markdown_to_html = _markdown_to_html

def _getDefaultTsConfig(testonly):
    if testonly:
        return _DEFAULT_TSCONFIG_TEST
    else:
        return _DEFAULT_TSCONFIG_BUILD

def ts_library(tsconfig = None, deps = [], testonly = False, **kwargs):
    # Add tslib because we use import helpers for all public packages.
    local_deps = ["@npm//tslib"] + deps

    if not tsconfig:
        tsconfig = _getDefaultTsConfig(testonly)

    _ts_library(
        tsconfig = tsconfig,
        testonly = testonly,
        # The default "ts_library" compiler does not come with "tsickle" available. Since
        # we have targets that use "tsickle" decorator processing, we need to ensure that
        # the compiler could load "tsickle" if needed.
        compiler = "//tools/bazel:tsc_wrapped_with_tsickle",
        deps = local_deps,
        **kwargs
    )

def ng_module(
        deps = [],
        srcs = [],
        tsconfig = None,
        module_name = None,
        flat_module_out_file = None,
        testonly = False,
        **kwargs):
    if not tsconfig:
        tsconfig = _getDefaultTsConfig(testonly)

    # Targets which have a module name and are not used for tests, should
    # have a default flat module out file named "index". This is necessary
    # as imports to that target should go through the flat module bundle.
    if module_name and not flat_module_out_file and not testonly:
        flat_module_out_file = "index"

    # Workaround to avoid a lot of changes to the Bazel build rules. Since
    # for most targets the flat module out file is "index.js", we cannot
    # include "index.ts" (if present) as source-file. This would resolve
    # in a conflict in the metadata bundler. Once we switch to Ivy and
    # no longer need metadata bundles, we can remove this logic.
    if flat_module_out_file == "index":
        if "index.ts" in srcs:
            srcs.remove("index.ts")

    local_deps = [
        # Add tslib because we use import helpers for all public packages.
        "@npm//tslib",
        "@npm//@angular/platform-browser",

        # Depend on the module typings for each `ng_module`. Since all components within the project
        # need to use `module.id` when creating components, this is always a dependency.
        "//src:module-typings",
    ]

    # Append given deps only if they're not in the default set of deps
    for d in deps:
        if d not in local_deps:
            local_deps = local_deps + [d]

    _ng_module(
        srcs = srcs,
        type_check = _ENABLE_NG_TYPE_CHECKING,
        module_name = module_name,
        flat_module_out_file = flat_module_out_file,
        deps = local_deps,
        tsconfig = tsconfig,
        testonly = testonly,
        **kwargs
    )

def ng_package(name, data = [], globals = ROLLUP_GLOBALS, readme_md = None, **kwargs):
    # If no readme file has been specified explicitly, use the default readme for
    # release packages from "src/README.md".
    if not readme_md:
        readme_md = "//src:README.md"

    # We need a genrule that copies the license into the current package. This
    # allows us to include the license in the "ng_package".
    native.genrule(
        name = "license_copied",
        srcs = ["//:LICENSE"],
        outs = ["LICENSE"],
        cmd = "cp $< $@",
    )

    _ng_package(
        name = name,
        globals = globals,
        data = data + [":license_copied"],
        readme_md = readme_md,
        replacements = VERSION_PLACEHOLDER_REPLACEMENTS,
        **kwargs
    )

def jasmine_node_test(**kwargs):
    _jasmine_node_test(**kwargs)

def ng_test_library(deps = [], tsconfig = None, **kwargs):
    local_deps = [
        # We declare "@angular/core" as default dependencies because
        # all Angular component unit tests use the `TestBed` and `Component` exports.
        "@npm//@angular/core",
        "@npm//@types/jasmine",
    ] + deps

    ts_library(
        testonly = 1,
        deps = local_deps,
        **kwargs
    )

def ng_e2e_test_library(deps = [], tsconfig = None, **kwargs):
    local_deps = [
        "@npm//@types/jasmine",
        "@npm//@types/selenium-webdriver",
        "@npm//protractor",
    ] + deps

    ts_library(
        testonly = 1,
        deps = local_deps,
        **kwargs
    )

def karma_web_test_suite(deps = [], srcs = [], **kwargs):
    _karma_web_test_suite(
        deps = ["//tools/rxjs:rxjs_umd_modules"] + deps,
        # Required for running the compiled ng modules that use TypeScript import helpers.
        # TODO(jelbourn): remove UMDs from here once we don't have to manually include them
        srcs = [
            "@npm//:node_modules/tslib/tslib.js",
        ] + ANGULAR_LIBRARY_UMDS + srcs,
        **kwargs
    )

# Protractor web test targets are flaky by default as the browser can sometimes
# crash (e.g. due to too much concurrency). Passing the "flaky" flag ensures that
# Bazel detects flaky tests and re-runs these a second time in case of a flake.
def protractor_web_test_suite(flaky = True, **kwargs):
    _protractor_web_test_suite(
        flaky = flaky,
        **kwargs
    )

def ng_web_test_suite(deps = [], static_css = [], bootstrap = [], tags = [], **kwargs):
    # Always include a prebuilt theme in the test suite because otherwise tests, which depend on CSS
    # that is needed for measuring, will unexpectedly fail. Also always adding a prebuilt theme
    # reduces the amount of setup that is needed to create a test suite Bazel target. Note that the
    # prebuilt theme will be also added to CDK test suites but shouldn't affect anything.
    static_css = static_css + [
        "//src/material/prebuilt-themes:indigo-pink",
        "//src/material-experimental/mdc-theming:indigo_pink_prebuilt",
    ]

    # Workaround for https://github.com/bazelbuild/rules_typescript/issues/301
    # Since some of our tests depend on CSS files which are not part of the `ng_module` rule,
    # we need to somehow load static CSS files within Karma (e.g. overlay prebuilt). Those styles
    # are required for successful test runs. Since the `karma_web_test_suite` rule currently only
    # allows JS files to be included and served within Karma, we need to create a JS file that
    # loads the given CSS file.
    for css_label in static_css:
        css_id = "static-css-file-%s" % (css_label.replace("/", "_").replace(":", "-"))
        deps += [":%s" % css_id]

        native.genrule(
            name = css_id,
            srcs = [css_label],
            outs = ["%s.js" % css_id],
            output_to_bindir = True,
            cmd = """
        files=($(locations %s))
        css_content=$$(cat $${files[0]})
        js_template="var cssElement = document.createElement('style'); \
                    cssElement.type = 'text/css'; \
                    cssElement.innerHTML = '$$css_content'; \
                    document.head.appendChild(cssElement);"

         echo $$js_template > $@
      """ % css_label,
        )

    karma_web_test_suite(
        # Depend on our custom test initialization script. This needs to be the first dependency.
        deps = [
            "//test:angular_test_init",
        ] + deps,
        browsers = [
            "@io_bazel_rules_webtesting//browsers:chromium-local",
            "@io_bazel_rules_webtesting//browsers:firefox-local",
        ],
        bootstrap = [
            "@npm//:node_modules/zone.js/dist/zone-testing-bundle.js",
            "@npm//:node_modules/reflect-metadata/Reflect.js",
            "@npm//:node_modules/hammerjs/hammer.js",
        ] + bootstrap,
        tags = ["native"] + tags,
        **kwargs
    )

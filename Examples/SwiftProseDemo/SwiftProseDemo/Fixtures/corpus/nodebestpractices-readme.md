[✔]: assets/images/checkbox-small-blue.png

# Node.js Best Practices

<h1 align="center">
  <img src="assets/images/banner-2.jpg" alt="Node.js Best Practices"/>
</h1>

<br/>

<div align="center">
  <img src="https://img.shields.io/badge/⚙%20Item%20count%20-%20102%20Best%20Practices-blue.svg" alt="102 items"/> <img id="last-update-badge" src="https://img.shields.io/badge/%F0%9F%93%85%20Last%20update%20-%20January%2024%2C%202023-green.svg" alt="Last update: January 3rd, 2024" /> <img src="https://img.shields.io/badge/ %E2%9C%94%20Updated%20For%20Version%20-%20Node%2022.0.0-brightgreen.svg" alt="Updated for Node 22.0.0"/>
</div>

<br/>

[<img src="assets/images/twitter.svg" width="16" height="16" alt="" />](https://twitter.com/nodepractices/) **Follow us on Twitter!** [**@nodepractices**](https://twitter.com/nodepractices/)

<br/>

Read in a different language: [![CN](./assets/flags/CN.png)**CN**](./README.chinese.md), [![FR](./assets/flags/FR.png)**FR**](./README.french.md), [![BR](./assets/flags/BR.png)**BR**](./README.brazilian-portuguese.md), [![RU](./assets/flags/RU.png)**RU**](./README.russian.md), [![PL](./assets/flags/PL.png)**PL**](./README.polish.md), [![JA](./assets/flags/JA.png)**JA**](./README.japanese.md), [![EU](./assets/flags/EU.png)**EU**](./README.basque.md) [(![ES](./assets/flags/ES.png)**ES**, ![HE](./assets/flags/HE.png)**HE**, ![KR](./assets/flags/KR.png)**KR** and ![TR](./assets/flags/TR.png)**TR** in progress! )](#translations)

<br/>

# 🎊 2026 edition is here!

- **🛰 Modernized to 2026**: Tons of text edits, new recommended libraries, and some new best practices

- **✨ Easily focus on new content**: Already visited before? Search for `#new` or `#updated` tags for new content only

- **🔖 Curious to see examples? We have a starter**: Visit [Practica.js](https://github.com/practicajs/practica), our application example and boilerplate (beta) to see some practices in action

<br/><br/>

# Welcome! 3 Things You Ought To Know First

**1. You are reading dozens of the best Node.js articles -** this repository is a summary and curation of the top-ranked content on Node.js best practices, as well as content written here by collaborators

**2. It is the largest compilation, and it is growing every week -** currently, more than 80 best practices, style guides, and architectural tips are presented. New issues and pull requests are created every day to keep this live book updated. We'd love to see you contributing here, whether that is fixing code mistakes, helping with translations, or suggesting brilliant new ideas. See our [writing guidelines here](./.operations/writing-guidelines.md)

**3. Best practices have additional info -** most bullets include a **🔗Read More** link that expands on the practice with code examples, quotes from selected blogs, and more information

<br/><br/>

# By Yoni Goldberg

### Learn with me: As a consultant, I engage with worldwide teams on various activities like workshops and code reviews. 🎉AND... Hold on, I've just launched my [beyond-the-basics testing course, which is on a 🎁 limited-time sale](https://testjavascript.com/) until August 7th

<br/><br/>

## Table of Contents

<details>
  <summary>
    <a href="#1-project-architecture-practices">1. Project Architecture Practices (6)</a>
  </summary>

&emsp;&emsp;[1.1 Structure your solution by components `#strategic` `#updated`](#-11-structure-your-solution-by-business-components)</br>
&emsp;&emsp;[1.2 Layer your components, keep the web layer within its boundaries `#strategic` `#updated`](#-12-layer-your-components-with-3-tiers-keep-the-web-layer-within-its-boundaries)</br>
&emsp;&emsp;[1.3 Wrap common utilities as packages, consider publishing](#-13-wrap-common-utilities-as-packages-consider-publishing)</br>
&emsp;&emsp;[1.4 Use environment aware, secure and hierarchical config `#updated`](#-14-use-environment-aware-secure-and-hierarchical-config)</br>
&emsp;&emsp;[1.5 Consider all the consequences when choosing the main framework `#new`](#-15-consider-all-the-consequences-when-choosing-the-main-framework)</br>
&emsp;&emsp;[1.6 Use TypeScript sparingly and thoughtfully `#new`](#-16-use-typescript-sparingly-and-thoughtfully)</br>

</details>

<details>
  <summary>
    <a href="#2-error-handling-practices">2. Error Handling Practices (12)</a>
  </summary>

&emsp;&emsp;[2.1 Use Async-Await or promises for async error handling](#-21-use-async-await-or-promises-for-async-error-handling)</br>
&emsp;&emsp;[2.2 Extend the built-in Error object `#strategic` `#updated`](#-22-extend-the-built-in-error-object)</br>
&emsp;&emsp;[2.3 Distinguish operational vs programmer errors `#strategic` `#updated`](#-23-distinguish-catastrophic-errors-from-operational-errors)</br>
&emsp;&emsp;[2.4 Handle errors centrally, not within a middleware `#strategic`](#-24-handle-errors-centrally-not-within-a-middleware)</br>
&emsp;&emsp;[2.5 Document API errors using OpenAPI or GraphQL](#-25-document-api-errors-using-openapi-or-graphql)</br>
&emsp;&emsp;[2.6 Exit the process gracefully when a stranger comes to town `#strategic`](#-26-exit-the-process-gracefully-when-a-stranger-comes-to-town)</br>
&emsp;&emsp;[2.7 Use a mature logger to increase errors visibility `#updated`](#-27-use-a-mature-logger-to-increase-errors-visibility)</br>
&emsp;&emsp;[2.8 Test error flows using your favorite test framework `#updated`](#-28-test-error-flows-using-your-favorite-test-framework)</br>
&emsp;&emsp;[2.9 Discover errors and downtime using APM products](#-29-discover-errors-and-downtime-using-apm-products)</br>
&emsp;&emsp;[2.10 Catch unhandled promise rejections `#updated`](#-210-catch-unhandled-promise-rejections)</br>
&emsp;&emsp;[2.11 Fail fast, validate arguments using a dedicated library](#-211-fail-fast-validate-arguments-using-a-dedicated-library)</br>
&emsp;&emsp;[2.12 Always await promises before returning to avoid a partial stacktrace `#new`](#-212-always-await-promises-before-returning-to-avoid-a-partial-stacktrace)</br>
&emsp;&emsp;[2.13 Subscribe to event emitters 'error' event `#new`](#-213-subscribe-to-event-emitters-and-streams-error-event)</br>

</details>

<details>
  <summary>
    <a href="#3-code-patterns-and-style-practices">3. Code Style Practices (12)</a>
  </summary>

&emsp;&emsp;[3.1 Use ESLint `#strategic`](#-31-use-eslint)</br>
&emsp;&emsp;[3.2 Use Node.js eslint extension plugins `#updated`](#-32-use-nodejs-eslint-extension-plugins)</br>
&emsp;&emsp;[3.3 Start a Codeblock's Curly Braces on the Same Line](#-33-start-a-codeblocks-curly-braces-on-the-same-line)</br>
&emsp;&emsp;[3.4 Separate your statements properly](#-34-separate-your-statements-properly)</br>
&emsp;&emsp;[3.5 Name your functions](#-35-name-your-functions)</br>
&emsp;&emsp;[3.6 Use naming conventions for variables, constants, functions and classes](#-36-use-naming-conventions-for-variables-constants-functions-and-classes)</br>
&emsp;&emsp;[3.7 Prefer const over let. Ditch the var](#-37-prefer-const-over-let-ditch-the-var)</br>
&emsp;&emsp;[3.8 Require modules first, not inside functions](#-38-require-modules-first-not-inside-functions)</br>
&emsp;&emsp;[3.9 Set an explicit entry point to a module/folder `#updated`](#-39-set-an-explicit-entry-point-to-a-modulefolder)</br>
&emsp;&emsp;[3.10 Use the === operator](#-310-use-the--operator)</br>
&emsp;&emsp;[3.11 Use Async Await, avoid callbacks `#strategic`](#-311-use-async-await-avoid-callbacks)</br>
&emsp;&emsp;[3.12 Use arrow function expressions (=>)](#-312-use-arrow-function-expressions-)</br>
&emsp;&emsp;[3.13 Avoid effects outside of functions `#new`](#-313-avoid-effects-outside-of-functions)</br>

</details>

<details>
  <summary>
    <a href="#4-testing-and-overall-quality-practices">4. Testing And Overall Quality Practices (13)</a>
  </summary>

&emsp;&emsp;[4.1 At the very least, write API (component) testing `#strategic`](#-41-at-the-very-least-write-api-component-testing)</br>
&emsp;&emsp;[4.2 Include 3 parts in each test name `#new`](#-42-include-3-parts-in-each-test-name)</br>
&emsp;&emsp;[4.3 Structure tests by the AAA pattern `#strategic`](#-43-structure-tests-by-the-aaa-pattern)</br>
&emsp;&emsp;[4.4 Ensure Node version is unified `#new`](#-44-ensure-node-version-is-unified)</br>
&emsp;&emsp;[4.5 Avoid global test fixtures and seeds, add data per-test `#strategic`](#-45-avoid-global-test-fixtures-and-seeds-add-data-per-test)</br>
&emsp;&emsp;[4.6 Tag your tests `#advanced`](#-46-tag-your-tests)</br>
&emsp;&emsp;[4.7 Check your test coverage, it helps to identify wrong test patterns](#-47-check-your-test-coverage-it-helps-to-identify-wrong-test-patterns)</br>
&emsp;&emsp;[4.8 Use production-like environment for e2e testing](#-48-use-production-like-environment-for-e2e-testing)</br>
&emsp;&emsp;[4.9 Refactor regularly using static analysis tools](#-49-refactor-regularly-using-static-analysis-tools)</br>
&emsp;&emsp;[4.10 Mock responses of external HTTP services #advanced `#new` `#advanced`](#-410-mock-responses-of-external-http-services)</br>
&emsp;&emsp;[4.11 Test your middlewares in isolation](#-411-test-your-middlewares-in-isolation)</br>
&emsp;&emsp;[4.12 Specify a port in production, randomize in testing `#new`](#-412-specify-a-port-in-production-randomize-in-testing)</br>
&emsp;&emsp;[4.13 Test the five possible outcomes #strategic `#new`](#-413-test-the-five-possible-outcomes)</br>

</details>

<details>
  <summary>
    <a href="#5-going-to-production-practices">5. Going To Production Practices (19)</a>
  </summary>

&emsp;&emsp;[5.1. Monitoring `#strategic`](#-51-monitoring)</br>
&emsp;&emsp;[5.2. Increase the observability using smart logging `#strategic`](#-52-increase-the-observability-using-smart-logging)</br>
&emsp;&emsp;[5.3. Delegate anything possible (e.g. gzip, SSL) to a reverse proxy `#strategic`](#-53-delegate-anything-possible-eg-gzip-ssl-to-a-reverse-proxy)</br>
&emsp;&emsp;[5.4. Lock dependencies](#-54-lock-dependencies)</br>
&emsp;&emsp;[5.5. Guard process uptime using the right tool](#-55-guard-process-uptime-using-the-right-tool)</br>
&emsp;&emsp;[5.6. Utilize all CPU cores](#-56-utilize-all-cpu-cores)</br>
&emsp;&emsp;[5.7. Create a ‘maintenance endpoint’](#-57-create-a-maintenance-endpoint)</br>
&emsp;&emsp;[5.8. Discover the unknowns using APM products `#advanced` `#updated`](#-58-discover-the-unknowns-using-apm-products)</br>
&emsp;&emsp;[5.9. Make your code production-ready](#-59-make-your-code-production-ready)</br>
&emsp;&emsp;[5.10. Measure and guard the memory usage `#advanced`](#-510-measure-and-guard-the-memory-usage)</br>
&emsp;&emsp;[5.11. Get your frontend assets out of Node](#-511-get-your-frontend-assets-out-of-node)</br>
&emsp;&emsp;[5.12. Strive to be stateless `#strategic`](#-512-strive-to-be-stateless)</br>
&emsp;&emsp;[5.13. Use tools that automatically detect vulnerabilities](#-513-use-tools-that-automatically-detect-vulnerabilities)</br>
&emsp;&emsp;[5.14. Assign a transaction id to each log statement `#advanced`](#-514-assign-a-transaction-id-to-each-log-statement)</br>
&emsp;&emsp;[5.15. Set NODE_ENV=production](#-515-set-node_envproduction)</br>
&emsp;&emsp;[5.16. Design automated, atomic and zero-downtime deployments `#advanced`](#-516-design-automated-atomic-and-zero-downtime-deployments)</br>
&emsp;&emsp;[5.17. Use an LTS release of Node.js](#-517-use-an-lts-release-of-nodejs)</br>
&emsp;&emsp;[5.18. Log to stdout, avoid specifying log destination within the app `#updated`](#-518-log-to-stdout-avoid-specifying-log-destination-within-the-app)</br>
&emsp;&emsp;[5.19. Install your packages with npm ci `#new`](#-519-install-your-packages-with-npm-ci)</br>

</details>

<details>
  <summary>
    <a href="#6-security-best-practices">6. Security Practices (25)</a>
  </summary>

&emsp;&emsp;[6.1. Embrace linter security rules](#-61-embrace-linter-security-rules)</br>
&emsp;&emsp;[6.2. Limit concurrent requests using a middleware](#-62-limit-concurrent-requests-using-a-middleware)</br>
&emsp;&emsp;[6.3 Extract secrets from config files or use packages to encrypt them `#strategic`](#-63-extract-secrets-from-config-files-or-use-packages-to-encrypt-them)</br>
&emsp;&emsp;[6.4. Prevent query injection vulnerabilities with ORM/ODM libraries `#strategic`](#-64-prevent-query-injection-vulnerabilities-with-ormodm-libraries)</br>
&emsp;&emsp;[6.5. Collection of generic security best practices](#-65-collection-of-generic-security-best-practices)</br>
&emsp;&emsp;[6.6. Adjust the HTTP response headers for enhanced security](#-66-adjust-the-http-response-headers-for-enhanced-security)</br>
&emsp;&emsp;[6.7. Constantly and automatically inspect for vulnerable dependencies `#strategic`](#-67-constantly-and-automatically-inspect-for-vulnerable-dependencies)</br>
&emsp;&emsp;[6.8. Protect Users' Passwords/Secrets using bcrypt or scrypt `#strategic`](#-68-protect-users-passwordssecrets-using-bcrypt-or-scrypt)</br>
&emsp;&emsp;[6.9. Escape HTML, JS and CSS output](#-69-escape-html-js-and-css-output)</br>
&emsp;&emsp;[6.10. Validate incoming JSON schemas `#strategic`](#-610-validate-incoming-json-schemas)</br>
&emsp;&emsp;[6.11. Support blocklisting JWTs](#-611-support-blocklisting-jwts)</br>
&emsp;&emsp;[6.12. Prevent brute-force attacks against authorization `#advanced`](#-612-prevent-brute-force-attacks-against-authorization)</br>
&emsp;&emsp;[6.13. Run Node.js as non-root user](#-613-run-nodejs-as-non-root-user)</br>
&emsp;&emsp;[6.14. Limit payload size using a reverse-proxy or a middleware](#-614-limit-payload-size-using-a-reverse-proxy-or-a-middleware)</br>
&emsp;&emsp;[6.15. Avoid JavaScript eval statements](#-615-avoid-javascript-eval-statements)</br>
&emsp;&emsp;[6.16. Prevent evil RegEx from overloading your single thread execution](#-616-prevent-evil-regex-from-overloading-your-single-thread-execution)</br>
&emsp;&emsp;[6.17. Avoid module loading using a variable](#-617-avoid-module-loading-using-a-variable)</br>
&emsp;&emsp;[6.18. Run unsafe code in a sandbox](#-618-run-unsafe-code-in-a-sandbox)</br>
&emsp;&emsp;[6.19. Take extra care when working with child processes `#advanced`](#-619-take-extra-care-when-working-with-child-processes)</br>
&emsp;&emsp;[6.20. Hide error details from clients](#-620-hide-error-details-from-clients)</br>
&emsp;&emsp;[6.21. Configure 2FA for npm or Yarn `#strategic`](#-621-configure-2fa-for-npm-or-yarn)</br>
&emsp;&emsp;[6.22. Modify session middleware settings](#-622-modify-session-middleware-settings)</br>
&emsp;&emsp;[6.23. Avoid DOS attacks by explicitly setting when a process should crash `#advanced`](#-623-avoid-dos-attacks-by-explicitly-setting-when-a-process-should-crash)</br>
&emsp;&emsp;[6.24. Prevent unsafe redirects](#-624-prevent-unsafe-redirects)</br>
&emsp;&emsp;[6.25. Avoid publishing secrets to the npm registry](#-625-avoid-publishing-secrets-to-the-npm-registry)</br>
&emsp;&emsp;[6.26. 6.26 Inspect for outdated packages](#-626-inspect-for-outdated-packages)</br>
&emsp;&emsp;[6.27. Import built-in modules using the 'node:' protocol `#new`](#-627-import-built-in-modules-using-the-node-protocol)</br>

</details>

<details>
  <summary>
    <a href="#7-draft-performance-best-practices">7. Performance Practices (2) (Work In Progress️ ✍️)</a>
  </summary>

&emsp;&emsp;[7.1. Don't block the event loop](#-71-dont-block-the-event-loop)</br>
&emsp;&emsp;[7.2. Prefer native JS methods over user-land utils like Lodash](#-72-prefer-native-js-methods-over-user-land-utils-like-lodash)</br>

</details>

<details>
  <summary>
    <a href="#8-docker-best-practices">8. Docker Practices (15)</a>
  </summary>

&emsp;&emsp;[8.1 Use multi-stage builds for leaner and more secure Docker images `#strategic`](#-81-use-multi-stage-builds-for-leaner-and-more-secure-docker-images)</br>
&emsp;&emsp;[8.2. Bootstrap using node command, avoid npm start](#-82-bootstrap-using-node-command-avoid-npm-start)</br>
&emsp;&emsp;[8.3. Let the Docker runtime handle replication and uptime `#strategic`](#-83-let-the-docker-runtime-handle-replication-and-uptime)</br>
&emsp;&emsp;[8.4. Use .dockerignore to prevent leaking secrets](#-84-use-dockerignore-to-prevent-leaking-secrets)</br>
&emsp;&emsp;[8.5. Clean-up dependencies before production](#-85-clean-up-dependencies-before-production)</br>
&emsp;&emsp;[8.6. Shutdown smartly and gracefully `#advanced`](#-86-shutdown-smartly-and-gracefully)</br>
&emsp;&emsp;[8.7. Set memory limits using both Docker and v8 `#advanced` `#strategic`](#-87-set-memory-limits-using-both-docker-and-v8)</br>
&emsp;&emsp;[8.8. Plan for efficient caching](#-88-plan-for-efficient-caching)</br>
&emsp;&emsp;[8.9. Use explicit image reference, avoid latest tag](#-89-use-explicit-image-reference-avoid-latest-tag)</br>
&emsp;&emsp;[8.10. Prefer smaller Docker base images](#-810-prefer-smaller-docker-base-images)</br>
&emsp;&emsp;[8.11. Clean-out build-time secrets, avoid secrets in args `#strategic #new`](#-811-clean-out-build-time-secrets-avoid-secrets-in-args)</br>
&emsp;&emsp;[8.12. Scan images for multi layers of vulnerabilities `#advanced`](#-812-scan-images-for-multi-layers-of-vulnerabilities)</br>
&emsp;&emsp;[8.13 Clean NODE_MODULE cache](#-813-clean-node_module-cache)</br>
&emsp;&emsp;[8.14. Generic Docker practices](#-814-generic-docker-practices)</br>
&emsp;&emsp;[8.15. Lint your Dockerfile `#new`](#-815-lint-your-dockerfile)</br>

</details>

<br/><br/>

# `1. Project Architecture Practices`

## ![✔] 1.1 Structure your solution by business components

### `📝 #updated`

**TL;DR:** The root of a system should contain folders or repositories that represent reasonably sized business modules. Each component represents a product domain (i.e., bounded context), like 'user-component', 'order-component', etc. Each component has its own API, logic, and logical database. What is the significant merit? With an autonomous component, every change is performed over a granular and smaller scope - the mental overload, development friction, and deployment fear are much smaller and better. As a result, developers can move much faster. This does not necessarily demand physical separation and can be achieved using a Monorepo or with a multi-repo

```bash
my-system
├─ apps (components)
│  ├─ orders
│  ├─ users
│  ├─ payments
├─ libraries (generic cross-component functionality)
│  ├─ logger
│  ├─ authenticator
```

**Otherwise:** when artifacts from various modules/topics are mixed together, there are great chances of a tightly-coupled 'spaghetti' system. For example, in an architecture where 'module-a controller' might call 'module-b service', there are no clear modularity borders - every code change might affect anything else. With this approach, developers who code new features struggle to realize the scope and impact of their change. Consequently, they fear breaking other modules, and each deployment becomes slower and riskier

🔗 [**Read More: structure by components**](./sections/projectstructre/breakintcomponents.md)

<br/><br/>

## ![✔] 1.2 Layer your components with 3-tiers, keep the web layer within its boundaries

### `📝 #updated`

**TL;DR:** Each component should contain 'layers' - a dedicated folder for common concerns: 'entry-point' where controller lives, 'domain' where the logic lives, and 'data-access'. The primary principle of the most popular architectures is to separate the technical concerns (e.g., HTTP, DB, etc) from the pure logic of the app so a developer can code more features without worrying about infrastructural concerns. Putting each concern in a dedicated folder, also known as the [3-Tier pattern](https://en.wikipedia.org/wiki/Multitier_architecture), is the _simplest_ way to meet this goal

```bash
my-system
├─ apps (components)
│  ├─ component-a
   │  ├─ entry-points
   │  │  ├─ api # controller comes here
   │  │  ├─ message-queue # message consumer comes here
   │  ├─ domain # features and flows: DTO, services, logic
   │  ├─ data-access # DB calls w/o ORM
```

**Otherwise:** It's often seen that developer pass web objects like request/response to functions in the domain/logic layer - this violates the separation principle and makes it harder to access later the logic code by other clients like testing code, scheduled jobs, message queues, etc

🔗 [**Read More: layer your app**](./sections/projectstructre/createlayers.md)

<br/><br/>

## ![✔] 1.3 Wrap common utilities as packages, consider publishing

**TL;DR:** Place all reusable modules in a dedicated folder, e.g., "libraries", and underneath each module in its own folder, e.g., "/libraries/logger". Make the module an independent package with its own package.json file to increase the module encapsulation, and allows future publishing to a repository. In a Monorepo setup, modules can be consumed by 'npm linking' to their physical paths, using ts-paths or by publishing and installing from a package manager repository like the npm registry

```bash
my-system
├─ apps (components)
  │  ├─ component-a
├─ libraries (generic cross-component functionality)
│  ├─ logger
│  │  ├─ package.json
│  │  ├─ src
│  │  │ ├─ index.js

```

**Otherwise:** Clients of a module might import and get coupled to internal functionality of a module. With a package.json at the root, one can set a package.json.main or package.json.exports to explicitly tell which files and functions are part of the public interface

🔗 [**Read More: Structure by feature**](./sections/projectstructre/wraputilities.md)

<br/><br/>

## ![✔] 1.4 Use environment aware, secure and hierarchical config

### `📝 #updated`

**TL;DR:** A flawless configuration setup should ensure (a) keys can be read from file AND from environment variable (b) secrets are kept outside committed code (c) config is hierarchical for easier findability (d) typing support (e) validation for failing fast (f) Specify default for each key. There are a few packages that can help tick most of those boxes like [convict](https://www.npmjs.com/package/convict), [env-var](https://github.com/evanshortiss/env-var), [zod](https://github.com/colinhacks/zod), and others

**Otherwise:** Consider a mandatory environment variable that wasn't provided. The app starts successfully and serve requests, some information is already persisted to DB. Then, it's realized that without this mandatory key the request can't complete, leaving the app in a dirty state

🔗 [**Read More: configuration best practices**](./sections/projectstructre/configguide.md)

<br/><br/>

## ![✔] 1.5 Consider all the consequences when choosing the main framework

### `🌟 #new`

**TL;DR:** When building apps and APIs, using a framework is mandatory. It's easy to overlook alternative frameworks or important considerations and then finally land on a sub optimal option. As of 2023/2024, we believe that these four frameworks are worth considering: [Nest.js](https://nestjs.com/), [Fastify](https://www.fastify.io/), [express](https://expressjs.com/), and [Koa](https://koajs.com/). Click read more below for a detailed pros/cons of each framework. Simplistically, we believe that Nest.js is the best match for teams who wish to go OOP and/or build large-scale apps that can't get partitioned into smaller _autonomous_ components. Fastify is our recommendation for apps with reasonably-sized components (e.g., Microservices) that are built around simple Node.js mechanics. Read our [full considerations guide here](./sections/projectstructre/choose-framework.md)

**Otherwise:** Due to the overwhelming amount of considerations, it's easy to make decisions based on partial information and compare apples with oranges. For example, it's believed that Fastify is a minimal web-server that should get compared with express only. In reality, it's a rich framework with many official plugins that cover many concerns

🔗 [**Read More: Choosing the right framework**](./sections/projectstructre/choose-framework.md)

## ![✔] 1.6 Use TypeScript sparingly and thoughtfully

### `🌟 #new`

**TL;DR:** Coding without type safety is no longer an option, TypeScript is the most popular option for this mission. Use it to define variables and functions return types. With that, it is also a double edge sword that can greatly _encourage_ complexity with its additional ~ 50 keywords and sophisticated features. Consider using it sparingly, mostly with simple types, and utilize advanced features only when a real need arises

**Otherwise:** [Researches](https://earlbarr.com/publications/typestudy.pdf) show that using TypeScript can help in detecting ~20% bugs earlier. Without it, also the developer experience in the IDE is intolerable. On the flip side, 80% of other bugs were not discovered using types. Consequently, typed syntax is valuable but limited. Only efficient tests can discover the whole spectrum of bugs, including type-related bugs. It might also defeat its purpose: sophisticated code features are likely to increase the code complexity, which by itself increases both the amount of bugs and the average bug fix time

🔗 [**Read More: TypeScript considerations**](./sections/projectstructre/typescript-considerations.md)

<br/><br/><br/>

<p align="right"><a href="#table-of-contents">⬆ Return to top</a></p>

# `2. Error Handling Practices`

## ![✔] 2.1 Use Async-Await or promises for async error handling

**TL;DR:** Handling async errors in callback style is probably the fastest way to hell (a.k.a the pyramid of doom). The best gift you can give to your code is using Promises with async-await which enables a much more compact and familiar code syntax like try-catch

**Otherwise:** Node.js callback style, function(err, response), is a promising way to un-maintainable code due to the mix of error handling with casual code, excessive nesting, and awkward coding patterns

🔗 [**Read More: avoiding callbacks**](./sections/errorhandling/asyncerrorhandling.md)

<br/><br/>

## ![✔] 2.2 Extend the built-in Error object

### `📝 #updated`

**TL;DR:** Some libraries throw errors as a string or as some custom type – this complicates the error handling logic and the interoperability between modules. Instead, create app error object/class that extends the built-in Error object and use it whenever rejecting, throwing or emitting an error. The app error should add useful imperative properties like the error name/code and isCatastrophic. By doing so, all errors have a unified structure and support better error handling. There is `no-throw-literal` ESLint rule that strictly checks that (although it has some [limitations](https://eslint.org/docs/rules/no-throw-literal) which can be solved when using TypeScript and setting the `@typescript-eslint/no-throw-literal` rule)

**Otherwise:** When invoking some component, being uncertain which type of errors come in return – it makes proper error handling much harder. Even worse, using custom types to describe errors might lead to loss of critical error information like the stack trace!

🔗 [**Read More: using the built-in error object**](./sections/errorhandling/useonlythebuiltinerror.md)

<br/><br/>

## ![✔] 2.3 Distinguish catastrophic errors from operational errors

### `📝 #updated`

**TL;DR:** Operational errors (e.g. API received an invalid input) refer to known cases where the error impact is fully understood and can be handled thoughtfully. On the other hand, catastrophic error (also known as programmer errors) refers to unusual code failures that dictate to gracefully restart the application

**Otherwise:** You may always restart the application when an error appears, but why let ~5000 online users down because of a minor, predicted, operational error? The opposite is also not ideal – keeping the application up when an unknown catastrophic issue (programmer error) occurred might lead to an unpredicted behavior. Differentiating the two allows acting tactfully and applying a balanced approach based on the given context

🔗 [**Read More: operational vs programmer error**](./sections/errorhandling/operationalvsprogrammererror.md)

<br/><br/>

## ![✔] 2.4 Handle errors centrally, not within a middleware

**TL;DR:** Error handling logic such as logging, deciding whether to crash and monitoring metrics should be encapsulated in a dedicated and centralized object that all entry-points (e.g. APIs, cron jobs, scheduled jobs) call when an error comes in

**Otherwise:** Not handling errors within a single place will lead to code duplication and probably to improperly handled errors

🔗 [**Read More: handling errors in a centralized place**](./sections/errorhandling/centralizedhandling.md)

<br/><br/>

## ![✔] 2.5 Document API errors using OpenAPI or GraphQL

**TL;DR:** Let your API callers know which errors might come in return so they can handle these thoughtfully without crashing. For RESTful APIs, this is usually done with documentation frameworks like OpenAPI. If you're using GraphQL, you can utilize your schema and comments as well

**Otherwise:** An API client might decide to crash and restart only because it received back an error it couldn’t understand. Note: the caller of your API might be you (very typical in a microservice environment)

🔗 [**Read More: documenting API errors in Swagger or GraphQL**](./sections/errorhandling/documentingusingswagger.md)

<br/><br/>

## ![✔] 2.6 Exit the process gracefully when a stranger comes to town

**TL;DR:** When an unknown error occurs (catastrophic error, see best practice 2.3) - there is uncertainty about the application healthiness. In this case, there is no escape from making the error observable, shutting off connections and exiting the process. Any reputable runtime framework like Dockerized services or cloud serverless solutions will take care to restart

**Otherwise:** When an unfamiliar exception occurs, some object might be in a faulty state (e.g. an event emitter which is used globally and not firing events anymore due to some internal failure) and all future requests might fail or behave crazily

🔗 [**Read More: shutting the process**](./sections/errorhandling/shuttingtheprocess.md)

<br/><br/>

## ![✔] 2.7 Use a mature logger to increase errors visibility

### `📝 #updated`

**TL;DR:** A robust logging tools like [Pino](https://github.com/pinojs/pino) or [Winston](https://github.com/winstonjs/winston) increases the errors visibility using features like log-levels, pretty print coloring and more. Console.log lacks these imperative features and should be avoided. The best in class logger allows attaching custom useful properties to log entries with minimized serialization performance penalty. Developers should write logs to `stdout` and let the infrastructure pipe the stream to the appropriate log aggregator

**Otherwise:** Skimming through console.logs or manually through messy text file without querying tools or a decent log viewer might keep you busy at work until late

🔗 [**Read More: using a mature logger**](./sections/errorhandling/usematurelogger.md)

<br/><br/>

## ![✔] 2.8 Test error flows using your favorite test framework

### `📝 #updated`

**TL;DR:** Whether professional automated QA or plain manual developer testing – Ensure that your code not only satisfies positive scenarios but also handles and returns the right errors. On top of this, simulate deeper error flows like uncaught exceptions and ensure that the error handler treat these properly (see code examples within the "read more" section)

**Otherwise:** Without testing, whether automatically or manually, you can’t rely on your code to return the right errors. Without meaningful errors – there’s no error handling

🔗 [**Read More: testing error flows**](./sections/errorhandling/testingerrorflows.md)

<br/><br/>

## ![✔] 2.9 Discover errors and downtime using APM products

**TL;DR:** Monitoring and performance products (a.k.a APM) proactively gauge your codebase or API so they can automagically highlight errors, crashes, and slow parts that you were missing

**Otherwise:** You might spend great effort on measuring API performance and downtimes, probably you’ll never be aware which are your slowest code parts under real-world scenario and how these affect the UX

🔗 [**Read More: using APM products**](./sections/errorhandling/apmproducts.md)

<br/><br/>

## ![✔] 2.10 Catch unhandled promise rejections

### `📝 #updated`

**TL;DR:** Any exception thrown within a promise will get swallowed and discarded unless a developer didn’t forget to explicitly handle it. Even if your code is subscribed to `process.uncaughtException`! Overcome this by registering to the event `process.unhandledRejection`

**Otherwise:** Your errors will get swallowed and leave no trace. Nothing to worry about

🔗 [**Read More: catching unhandled promise rejection**](./sections/errorhandling/catchunhandledpromiserejection.md)

<br/><br/>

## ![✔] 2.11 Fail fast, validate arguments using a dedicated library

**TL;DR:** Assert API input to avoid nasty bugs that are much harder to track later. The validation code is usually tedious unless you are using a modern validation library like [ajv](https://www.npmjs.com/package/ajv), [zod](https://github.com/colinhacks/zod), or [typebox](https://github.com/sinclairzx81/typebox)

**Otherwise:** Consider this – your function expects a numeric argument “Discount” which the caller forgets to pass, later on, your code checks if Discount!=0 (amount of allowed discount is greater than zero), then it will allow the user to enjoy a discount. OMG, what a nasty bug. Can you see it?

🔗 [**Read More: failing fast**](./sections/errorhandling/failfast.md)

<br/><br/>

## ![✔] 2.12 Always await promises before returning to avoid a partial stacktrace

### `🌟 #new`

**TL;DR:** Always do `return await` when returning a promise to benefit full error stacktrace. If a
function returns a promise, that function must be declared as `async` function and explicitly
`await` the promise before returning it

**Otherwise:** The function that returns a promise without awaiting won't appear in the stacktrace.
Such missing frames would probably complicate the understanding of the flow that leads to the error,
especially if the cause of the abnormal behavior is inside of the missing function

🔗 [**Read More: returning promises**](./sections/errorhandling/returningpromises.md)

<br/><br/>

## ![✔] 2.13 Subscribe to event emitters and streams 'error' event

### `🌟 #new`

**TL;DR:** Unlike typical functions, a try-catch clause won't get errors that originate from Event Emitters and anything inherited from it (e.g., streams). Instead of try-catch, subscribe to an event emitter's 'error' event so your code can handle the error in context. When dealing with [EventTargets](https://nodejs.org/api/events.html#eventtarget-and-event-api) (the web standard version of Event Emitters) there are no 'error' event and all errors end in the process.on('error) global event - in this case, at least ensure that the process crash or not based on the desired context. Also, mind that error originating from _asynchronous_ event handlers are not get caught unless the event emitter is initialized with {captureRejections: true}

**Otherwise:** Event emitters are commonly used for global and key application functionality such as DB or message queue connection. When this kind of crucial objects throw an error, at best the process will crash due to unhandled exception. Even worst, it will stay alive as a zombie while a key functionality is turned off

<br/><br/><br/>

<p align="right"><a href="#table-of-contents">⬆ Return to top</a></p>

# `3. Code Patterns And Style Practices`

## ![✔] 3.1 Use ESLint

**TL;DR:** [ESLint](https://eslint.org) is the de-facto standard for checking possible code errors and fixing code style, not only to identify nitty-gritty spacing issues but also to detect serious code anti-patterns like developers throwing errors without classification. Though ESLint can automatically fix code styles, other tools like [prettier](https://www.npmjs.com/package/prettier) are more powerful in formatting the fix and work in conjunction with ESLint

**Otherwise:** Developers will focus on tedious spacing and line-width concerns and time might be wasted overthinking the project's code style

🔗 [**Read More: Using ESLint and Prettier**](./sections/codestylepractices/eslint_prettier.md)

<br/><br/>

## ![✔] 3.2 Use Node.js eslint extension plugins

### `📝 #updated`

**TL;DR:** On top of ESLint standard rules that cover vanilla JavaScript, add Node.js specific plugins like [eslint-plugin-node](https://www.npmjs.com/package/eslint-plugin-node), [eslint-plugin-mocha](https://www.npmjs.com/package/eslint-plugin-mocha) and [eslint-plugin-node-security](https://www.npmjs.com/package/eslint-plugin-security), [eslint-plugin-require](https://www.npmjs.com/package/eslint-plugin-require), [/eslint-plugin-jest](https://www.npmjs.com/package/eslint-plugin-jest) and other useful rules

**Otherwise:** Many faulty Node.js code patterns might escape under the radar. For example, developers might require(variableAsPath) files with a variable given as a path which allows attackers to execute any JS script. Node.js linters can detect such patterns and complain early

<br/><br/>

## ![✔] 3.3 Start a Codeblock's Curly Braces on the Same Line

**TL;DR:** The opening curly braces of a code block should be on the same line as the opening statement

### Code Example

```javascript
// Do
function someFunction() {
  // code block
}

// Avoid
function someFunction()
{
  // code block
}
```

**Otherwise:** Deferring from this best practice might lead to unexpected results, as seen in the StackOverflow thread below:

🔗 [**Read more:** "Why do results vary based on curly brace placement?" (StackOverflow)](https://stackoverflow.com/questions/3641519/why-does-a-results-vary-based-on-curly-brace-placement)

<br/><br/>

## ![✔] 3.4 Separate your statements properly

No matter if you use semicolons or not to separate your statements, knowing the common pitfalls of improper linebreaks or automatic semicolon insertion, will help you to eliminate regular syntax errors.

**TL;DR:** Use ESLint to gain awareness about separation concerns. [Prettier](https://prettier.io/) or [Standardjs](https://standardjs.com/) can automatically resolve these issues.

**Otherwise:** As seen in the previous section, JavaScript's interpreter automatically adds a semicolon at the end of a statement if there isn't one, or considers a statement as not ended where it should, which might lead to some undesired results. You can use assignments and avoid using immediately invoked function expressions to prevent most of the unexpected errors.

### Code example

```javascript
// Do
function doThing() {
    // ...
}

doThing()

// Do

const items = [1, 2, 3]
items.forEach(console.log)

// Avoid — throws exception
const m = new Map()
const a = [1,2,3]
[...m.values()].forEach(console.log)
> [...m.values()].forEach(console.log)
>  ^^^
> SyntaxError: Unexpected token ...

// Avoid — throws exception
const count = 2 // it tries to run 2(), but 2 is not a function
(function doSomething() {
  // do something amazing
}())
// put a semicolon before the immediate invoked function, after the const definition, save the return value of the anonymous function to a variable or avoid IIFEs altogether
```

🔗 [**Read more:** "Semi ESLint rule"](https://eslint.org/docs/rules/semi)
🔗 [**Read more:** "No unexpected multiline ESLint rule"](https://eslint.org/docs/rules/no-unexpected-multiline)

<br/><br/>

## ![✔] 3.5 Name your functions

**TL;DR:** Name all functions, including closures and callbacks. Avoid anonymous functions. This is especially useful when profiling a node app. Naming all functions will allow you to easily understand what you're looking at when checking a memory snapshot

**Otherwise:** Debugging production issues using a core dump (memory snapshot) might become challenging as you notice significant memory consumption from anonymous functions

<br/><br/>

## ![✔] 3.6 Use naming conventions for variables, constants, functions and classes

**TL;DR:** Use **_lowerCamelCase_** when naming constants, variables and functions, **_UpperCamelCase_** (capital first letter as well) when naming classes and **_UPPER_SNAKE_CASE_** when naming global or static variables. This will help you to easily distinguish between plain variables, functions, classes that require instantiation and variables declared at global module scope. Use descriptive names, but try to keep them short

**Otherwise:** JavaScript is the only language in the world that allows invoking a constructor ("Class") directly without instantiating it first. Consequently, Classes and function-constructors are differentiated by starting with UpperCamelCase

### 3.6 Code Example

```javascript
// for global variables names we use the const/let keyword and UPPER_SNAKE_CASE
let MUTABLE_GLOBAL = "mutable value";
const GLOBAL_CONSTANT = "immutable value";
const CONFIG = {
  key: "value",
};

// examples of UPPER_SNAKE_CASE convention in nodejs/javascript ecosystem
// in javascript Math.PI module
const PI = 3.141592653589793;

// https://github.com/nodejs/node/blob/b9f36062d7b5c5039498e98d2f2c180dca2a7065/lib/internal/http2/core.js#L303
// in nodejs http2 module
const HTTP_STATUS_OK = 200;
const HTTP_STATUS_CREATED = 201;

// for class name we use UpperCamelCase
class SomeClassExample {
  // for static class properties we use UPPER_SNAKE_CASE
  static STATIC_PROPERTY = "value";
}

// for functions names we use lowerCamelCase
function doSomething() {
  // for scoped variable names we use the const/let keyword and lowerCamelCase
  const someConstExample = "immutable value";
  let someMutableExample = "mutable value";
}
```

<br/><br/>

## ![✔] 3.7 Prefer const over let. Ditch the var

**TL;DR:** Using `const` means that once a variable is assigned, it cannot be reassigned. Preferring `const` will help you to not be tempted to use the same variable for different uses, and make your code clearer. If a variable needs to be reassigned, in a for loop, for example, use `let` to declare it. Another important aspect of `let` is that a variable declared using it is only available in the block scope in which it was defined. `var` is function scoped, not block-scoped, and [shouldn't be used in ES6](https://hackernoon.com/why-you-shouldnt-use-var-anymore-f109a58b9b70) now that you have `const` and `let` at your disposal

**Otherwise:** Debugging becomes way more cumbersome when following a variable that frequently changes

🔗 [**Read more: JavaScript ES6+: var, let, or const?** ](https://medium.com/javascript-scene/javascript-es6-var-let-or-const-ba58b8dcde75)

<br/><br/>

## ![✔] 3.8 Require modules first, not inside functions

**TL;DR:** Require modules at the beginning of each file, before and outside of any functions. This simple best practice will not only help you easily and quickly tell the dependencies of a file right at the top but also avoids a couple of potential problems

**Otherwise:** Requires are run synchronously by Node.js. If they are called from within a function, it may block other requests from being handled at a more critical time. Also, if a required module or any of its dependencies throw an error and crash the server, it is best to find out about it as soon as possible, which might not be the case if that module is required from within a function

<br/><br/>

## ![✔] 3.9 Set an explicit entry point to a module/folder

### `📝 #updated`

**TL;DR:** When developing a module/library, set an explicit root file that exports the public and interesting code. Discourage the client code from importing deep files and becoming familiar with the internal structure. With commonjs (require), this can be done with an index.js file at the folder's root or the package.json.main field. With ESM (import), if a package.json exists on the root, the field "exports" allow specifying the module's root file. If no package.json exists, you may put an index.js file on the root which re-exports all the public functionality

**Otherwise:** Having an explicit root file acts like a public 'interface' that encapsulates the internal, directs the caller to the public code and facilitates future changes without breaking the contract

### 3.9 Code example - avoid coupling the client to the module structure

```javascript
// Avoid: client has deep familiarity with the internals

// Client code
const SMSWithMedia = require("./SMSProvider/providers/media/media-provider.js");

// Better: explicitly export the public functions

//index.js, module code
module.exports.SMSWithMedia = require("./SMSProvider/providers/media/media-provider.js");

// Client code
const { SMSWithMedia } = require("./SMSProvider");
```

<br/><br/>

## ![✔] 3.10 Use the `===` operator

**TL;DR:** Prefer the strict equality operator `===` over the weaker abstract equality operator `==`. `==` will compare two variables after converting them to a common type. There is no type conversion in `===`, and both variables must be of the same type to be equal

**Otherwise:** Unequal variables might return true when compared with the `==` operator

### 3.10 Code example

```javascript
"" == "0"; // false
0 == ""; // true
0 == "0"; // true

false == "false"; // false
false == "0"; // true

false == undefined; // false
false == null; // false
null == undefined; // true

" \t\r\n " == 0; // true
```

All statements above will return false if used with `===`

<br/><br/>

## ![✔] 3.11 Use Async Await, avoid callbacks

**TL;DR:** Async-await is the simplest way to express an asynchronous flow as it makes asynchronous code look synchronous. Async-await will also result in much more compact code and support for try-catch. This technique now supersedes callbacks and promises in _most_ cases. Using it in your code is probably the best gift one can give to the code reader

**Otherwise:** Handling async errors in callback style are probably the fastest way to hell - this style forces to check errors all over, deal with awkward code nesting, and makes it difficult to reason about the code flow

🔗[**Read more:** Guide to async-await 1.0](https://github.com/yortus/asyncawait)

<br/><br/>

## ![✔] 3.12 Use arrow function expressions (=>)

**TL;DR:** Though it's recommended to use async-await and avoid function parameters when dealing with older APIs that accept promises or callbacks - arrow functions make the code structure more compact and keep the lexical context of the root function (i.e. `this`)

**Otherwise:** Longer code (in ES5 functions) is more prone to bugs and cumbersome to read

🔗 [**Read more: It’s Time to Embrace Arrow Functions**](https://medium.com/javascript-scene/familiarity-bias-is-holding-you-back-its-time-to-embrace-arrow-functions-3d37e1a9bb75)

<br/><br/>

## ![✔] 3.13 Avoid effects outside of functions

### `🌟 #new`

**TL;DR:** Avoid putting code with effects like network or DB calls outside of functions. Such a code will be executed immediately when another file requires the file. This 'floating' code might get executed when the underlying system is not ready yet. It also comes with a performance penalty even when this module's functions will finally not be used in runtime. Last, mocking these DB/network calls for testing is harder outside of functions. Instead, put this code inside functions that should get called explicitly. If some DB/network code must get executed right when the module loads, consider using the factory or revealing module patterns

**Otherwise:** A typical web framework sets error handler, environment variables and monitoring. When DB/network calls are made before the web framework is initialized, they won't be monitored or fail due to a lack of configuration data

<br/><br/><br/>

<p align="right"><a href="#table-of-contents">⬆ Return to top</a></p>

# `4. Testing And Overall Quality Practices`

\_We have dedicated guides for testing, see below. The best practices list here is a brief summary of these guides

a. [JavaScript testing best practices](https://github.com/goldbergyoni/javascript-testing-best-practices)
b. [Node.js testing - beyond the basics](https://github.com/testjavascript/nodejs-integration-tests-best-practices)
\_

## ![✔] 4.1 At the very least, write API (component) testing

**TL;DR:** Most projects just don't have any automated testing due to short timetables or often the 'testing project' ran out of control and was abandoned. For that reason, prioritize and start with API testing which is the easiest way to write and provides more coverage than unit testing (you may even craft API tests without code using tools like [Postman](https://www.getpostman.com/)). Afterwards, should you have more resources and time, continue with advanced test types like unit testing, DB testing, performance testing, etc

**Otherwise:** You may spend long days on writing unit tests to find out that you got only 20% system coverage

<br/><br/>

## ![✔] 4.2 Include 3 parts in each test name

### `🌟 #new`

**TL;DR:** Make the test speak at the requirements level so it's self-explanatory also to QA engineers and developers who are not familiar with the code internals. State in the test name what is being tested (unit under test), under what circumstances, and what is the expected result

**Otherwise:** A deployment just failed, a test named “Add product” failed. Does this tell you what exactly is malfunctioning?

🔗 [**Read More: Include 3 parts in each test name**](./sections/testingandquality/3-parts-in-name.md)

<br/><br/>

## ![✔] 4.3 Structure tests by the AAA pattern

### `🌟 #new`

**TL;DR:** Structure your tests with 3 well-separated sections: Arrange, Act & Assert (AAA). The first part includes the test setup, then the execution of the unit under test, and finally the assertion phase. Following this structure guarantees that the reader spends no brain CPU on understanding the test plan

**Otherwise:** Not only you spend long daily hours on understanding the main code, but now also what should have been the simple part of the day (testing) stretches your brain

🔗 [**Read More: Structure tests by the AAA pattern**](./sections/testingandquality/aaa.md)

<br/><br/>

## ![✔] 4.4 Ensure Node version is unified

### `🌟 #new`

**TL;DR:** Use tools that encourage or enforce the same Node.js version across different environments and developers. Tools like [nvm](https://github.com/nvm-sh/nvm), and [Volta](https://volta.sh/) allow specifying the project's version in a file so each team member can run a single command to conform with the project's version. Optionally, this definition can be replicated to CI and the production runtime (e.g., copy the specified value to .Dockerfile build and to the CI declaration file)

**Otherwise:** A developer might face or miss an error because she uses a different Node.js version than her teammates. Even worse - the production runtime might be different than the environment where tests were executed

<br/><br/>

## ![✔] 4.5 Avoid global test fixtures and seeds, add data per-test

**TL;DR:** To prevent test coupling and easily reason about the test flow, each test should add and act on its own set of DB rows. Whenever a test needs to pull or assume the existence of some DB data - it must explicitly add that data and avoid mutating any other records

**Otherwise:** Consider a scenario where deployment is aborted due to failing tests, team is now going to spend precious investigation time that ends in a sad conclusion: the system works well, the tests however interfere with each other and break the build

🔗 [**Read More: Avoid global test fixtures**](./sections/testingandquality/avoid-global-test-fixture.md)

<br/><br/>

## ![✔] 4.6 Tag your tests

**TL;DR:** Different tests must run on different scenarios: quick smoke, IO-less, tests should run when a developer saves or commits a file, full end-to-end tests usually run when a new pull request is submitted, etc. This can be achieved by tagging tests with keywords like #cold #api #sanity so you can grep with your testing harness and invoke the desired subset. For example, this is how you would invoke only the sanity test group with [Mocha](https://mochajs.org/): mocha --grep 'sanity'

**Otherwise:** Running all the tests, including tests that perform dozens of DB queries, any time a developer makes a small change can be extremely slow and keeps developers away from running tests

<br/><br/>

## ![✔] 4.7 Check your test coverage, it helps to identify wrong test patterns

**TL;DR:** Code coverage tools like [Istanbul](https://github.com/istanbuljs/istanbuljs)/[NYC](https://github.com/istanbuljs/nyc) are great for 3 reasons: it comes for free (no effort is required to benefit this reports), it helps to identify a decrease in testing coverage, and last but not least it highlights testing mismatches: by looking at colored code coverage reports you may notice, for example, code areas that are never tested like catch clauses (meaning that tests only invoke the happy paths and not how the app behaves on errors). Set it to fail builds if the coverage falls under a certain threshold

**Otherwise:** There won't be any automated metric telling you when a large portion of your code is not covered by testing

<br/><br/>

## ![✔] 4.8 Use production-like environment for e2e testing

**TL;DR:** End to end (e2e) testing which includes live data used to be the weakest link of the CI process as it depends on multiple heavy services like DB. Use an environment which is as close to your real production environment as possible like a-continue (Missed -continue here, needs content. Judging by the **Otherwise** clause, this should mention docker-compose)

**Otherwise:** Without docker-compose, teams must maintain a testing DB for each testing environment including developers' machines, keep all those DBs in sync so test results won't vary across environments

<br/><br/>

## ![✔] 4.9 Refactor regularly using static analysis tools

**TL;DR:** Using static analysis tools helps by giving objective ways to improve code quality and keeps your code maintainable. You can add static analysis tools to your CI build to fail when it finds code smells. Its main selling points over plain linting are the ability to inspect quality in the context of multiple files (e.g. detect duplications), perform advanced analysis (e.g. code complexity), and follow the history and progress of code issues. Two examples of tools you can use are [Sonarqube](https://www.sonarqube.org/) (2,600+ [stars](https://github.com/SonarSource/sonarqube)) and [Code Climate](https://codeclimate.com/) (1,500+ [stars](https://github.com/codeclimate/codeclimate)).

**Otherwise:** With poor code quality, bugs and performance will always be an issue that no shiny new library or state of the art features can fix

🔗 [**Read More: Refactoring!**](./sections/testingandquality/refactoring.md)

<br/><br/>

## ![✔] 4.10 Mock responses of external HTTP services

### `🌟 #new`

**TL;DR:** Use network mocking tools to simulate responses of external collaborators' services that are approached over the network (e.g., REST, Graph). This is imperative not only to isolate the component under test but mostly to simulate non-happy path flows. Tools like [nock](https://github.com/nock/nock) (in-process) or [Mock-Server](https://www.mock-server.com/) allow defining a specific response of external service in a single line of code. Remember to simulate also errors, delays, timeouts, and any other event that is likely to happen in production

**Otherwise:** Allowing your component to reach real external services instances will likely result in naive tests that mostly cover happy paths. The tests might also be flaky and slow

🔗 [**Read More: Mock external services**](./sections/testingandquality/mock-external-services.md)

## ![✔] 4.11 Test your middlewares in isolation

**TL;DR:** When a middleware holds some immense logic that spans many requests, it is worth testing it in isolation without waking up the entire web framework. This can be easily achieved by stubbing and spying on the {req, res, next} objects

**Otherwise:** A bug in Express middleware === a bug in all or most requests

🔗 [**Read More: Test middlewares in isolation**](./sections/testingandquality/test-middlewares.md)

## ![✔] 4.12 Specify a port in production, randomize in testing

### `🌟 #new`

**TL;DR:** When testing against the API, it's common and desirable to initialize the web server inside the tests. Let the server randomize the web server port in testing to prevent collisions. If you're using Node.js http server (used by most frameworks), doing so demands nothing but passing a port number zero - this will randomize an available port

**Otherwise:** Specifying a fixed port will prevent two testing processes from running at the same time. Most of the modern test runners run with multiple processes by default

🔗 [**Read More: Randomize a port for testing**](./sections/testingandquality/randomize-port.md)

## ![✔] 4.13 Test the five possible outcomes

### `🌟 #new`

**TL;DR:** When testing a flow, ensure to cover five potential categories. Any time some action is triggered (e.g., API call), a reaction occurs, a meaningful **outcome** is produced and calls for testing. There are five possible outcome types for every flow: a response, a visible state change (e.g., DB), an outgoing API call, a new message in a queue, and an observability call (e.g., logging, metric). See a [checklist here](https://testjavascript.com/wp-content/uploads/2021/10/the-backend-checklist.pdf). Each type of outcome comes with unique challenges and techniques to mitigate those challenges - we have a dedicated guide about this topic: [Node.js testing - beyond the basics](https://github.com/testjavascript/nodejs-integration-tests-best-practices)

**Otherwise:** Consider a case when testing the addition of a new product to the system. It's common to see tests that assert on a valid response only. What if the product was failed to persist regardless of the positive response? what if when adding a new product demands calling some external service, or putting a message in the queue - shouldn't the test assert these outcomes as well? It's easy to overlook various paths, this is where a [checklist comes handy](https://testjavascript.com/wp-content/uploads/2021/10/the-backend-checklist.pdf)

🔗 [**Read More: Test five outcomes**](./sections/testingandquality/test-five-outcomes.md)

<br/><br/><br/>

<p align="right"><a href="#table-of-contents">⬆ Return to top</a></p>

# `5. Going To Production Practices`

## ![✔] 5.1. Monitoring

**TL;DR:** Monitoring is a game of finding out issues before customers do – obviously this should be assigned unprecedented importance. The market is overwhelmed with offers thus consider starting with defining the basic metrics you must follow (my suggestions inside), then go over additional fancy features and choose the solution that ticks all boxes. In any case, the 4 layers of observability must be covered: uptime, metrics with focus on user-facing symptoms and Node.js technical metrics like event loop lag, distributed flows measurement with Open Telemetry and logging. Click ‘Read More’ below for an overview of the solutions

**Otherwise:** Failure === disappointed customers. Simple

🔗 [**Read More: Monitoring!**](./sections/production/monitoring.md)

<br/><br/>

## ![✔] 5.2. Increase the observability using smart logging

**TL;DR:** Logs can be a dumb warehouse of debug statements or the enabler of a beautiful dashboard that tells the story of your app. Plan your logging platform from day 1: how logs are collected, stored and analyzed to ensure that the desired information (e.g. error rate, following an entire transaction through services and servers, etc) can really be extracted

**Otherwise:** You end up with a black box that is hard to reason about, then you start re-writing all logging statements to add additional information

🔗 [**Read More: Increase transparency using smart logging**](./sections/production/smartlogging.md)

<br/><br/>

## ![✔] 5.3. Delegate anything possible (e.g. gzip, SSL) to a reverse proxy

**TL;DR:** Node is quite bad at doing CPU intensive tasks like gzipping, SSL termination, etc. You should use specialized infrastructure like nginx, HAproxy or cloud vendor services instead

**Otherwise:** Your poor single thread will stay busy doing infrastructural tasks instead of dealing with your application core and performance will degrade accordingly

🔗 [**Read More: Delegate anything possible (e.g. gzip, SSL) to a reverse proxy**](./sections/production/delegatetoproxy.md)

<br/><br/>

## ![✔] 5.4. Lock dependencies

**TL;DR:** Your code must be identical across all environments, but without a special lockfile npm lets dependencies drift across environments. Ensure to commit your package-lock.json so all the environments will be identical

**Otherwise:** QA will thoroughly test the code and approve a version that will behave differently in production. Even worse, different servers in the same production cluster might run different code

🔗 [**Read More: Lock dependencies**](./sections/production/lockdependencies.md)

<br/><br/>

## ![✔] 5.5. Guard process uptime using the right tool

**TL;DR:** The process must go on and get restarted upon failures. Modern runtime platforms like Docker-ized platforms (e.g. Kubernetes), and Serverless take care for this automatically. When the app is hosted on a bare metal server, one must take care for a process management tools like [systemd](https://systemd.io/). Avoid including a custom process management tool in a modern platform that monitors an app instance (e.g., Kubernetes) - doing so will hide failures from the infrastructure. When the underlying infrastructure is not aware of errors, it can't perform useful mitigation steps like re-placing the instance in a different location

**Otherwise:** Running dozens of instances without a clear strategy and too many tools together (cluster management, docker, PM2) might lead to DevOps chaos

🔗 [**Read More: Guard process uptime using the right tool**](./sections/production/guardprocess.md)

<br/><br/>

## ![✔] 5.6. Utilize all CPU cores

**TL;DR:** At its basic form, a Node app runs on a single CPU core while all others are left idling. It’s your duty to replicate the Node process and utilize all CPUs. Most of the modern run-times platform (e.g., Kubernetes) allow replicating instances of the app but they won't verify that all cores are utilized - this is your duty. If the app is hosted on a bare server, it's also your duty to use some process replication solution (e.g. systemd)

**Otherwise:** Your app will likely utilize only 25% of its available resources(!) or even less. Note that a typical server has 4 CPU cores or more, naive deployment of Node.js utilizes only 1 (even using PaaS services like AWS beanstalk!)

🔗 [**Read More: Utilize all CPU cores**](./sections/production/utilizecpu.md)

<br/><br/>

## ![✔] 5.7. Create a ‘maintenance endpoint’

**TL;DR:** Expose a set of system-related information, like memory usage and REPL, etc in a secured API. Although it’s highly recommended to rely on standard and battle-tested tools, some valuable information and operations are easier done using code

**Otherwise:** You’ll find that you’re performing many “diagnostic deploys” – shipping code to production only to extract some information for diagnostic purposes

🔗 [**Read More: Create a ‘maintenance endpoint’**](./sections/production/createmaintenanceendpoint.md)

<br/><br/>

## ![✔] 5.8. Discover the unknowns using APM products

### `📝 #updated`

**TL;DR:** Consider adding another safety layer to the production stack - APM. While the majority of symptoms and causes can be detected using traditional monitoring techniques, in a distributed system there is more than meets the eye. Application monitoring and performance products (a.k.a. APM) can auto-magically go beyond traditional monitoring and provide additional layer of discovery and developer-experience. For example, some APM products can highlight a transaction that loads too slow on the **end-user's side** while suggesting the root cause. APMs also provide more context for developers who try to troubleshoot a log error by showing what was the server busy with when the error occurred. To name a few example

**Otherwise:** You might spend great effort on measuring API performance and downtimes, probably you’ll never be aware which is your slowest code parts under real-world scenario and how these affect the UX

🔗 [**Read More: Discover errors and downtime using APM products**](./sections/production/apmproducts.md)

<br/><br/>

## ![✔] 5.9. Make your code production-ready

**TL;DR:** Code with the end in mind, plan for production from day 1. This sounds a bit vague so I’ve compiled a few development tips that are closely related to production maintenance (click 'Read More')

**Otherwise:** A world champion IT/DevOps guy won’t save a system that is badly written

🔗 [**Read More: Make your code production-ready**](./sections/production/productioncode.md)

<br/><br/>

## ![✔] 5.10. Measure and guard the memory usage

**TL;DR:** Node.js has controversial relationships with memory: the v8 engine has soft limits on memory usage (1.4GB) and there are known paths to leak memory in Node’s code – thus watching Node’s process memory is a must. In small apps, you may gauge memory periodically using shell commands but in medium-large apps consider baking your memory watch into a robust monitoring system

**Otherwise:** Your process memory might leak a hundred megabytes a day like how it happened at [Walmart](https://www.joyent.com/blog/walmart-node-js-memory-leak)

🔗 [**Read More: Measure and guard the memory usage**](./sections/production/measurememory.md)

<br/><br/>

## ![✔] 5.11. Get your frontend assets out of Node

**TL;DR:** Serve frontend content using a specialized infrastructure (nginx, S3, CDN) because Node performance gets hurt when dealing with many static files due to its single-threaded model. One exception to this guideline is when doing server-side rendering

**Otherwise:** Your single Node thread will be busy streaming hundreds of html/images/angular/react files instead of allocating all its resources for the task it was born for – serving dynamic content

🔗 [**Read More: Get your frontend assets out of Node**](./sections/production/frontendout.md)

<br/><br/>

## ![✔] 5.12. Strive to be stateless

**TL;DR:** Store any type of _data_ (e.g. user sessions, cache, uploaded files) within external data stores. When the app holds data in-process this adds additional layer of maintenance complexity like routing users to the same instance and higher cost of restarting a process. To enforce and encourage a stateless approach, most modern runtime platforms allows 'reapp-ing' instances periodically

**Otherwise:** Failure at a given server will result in application downtime instead of just killing a faulty machine. Moreover, scaling-out elasticity will get more challenging due to the reliance on a specific server

🔗 [**Read More: Be stateless, kill your Servers almost every day**](./sections/production/bestateless.md)

<br/><br/>

## ![✔] 5.13. Use tools that automatically detect vulnerabilities

**TL;DR:** Even the most reputable dependencies such as Express have known vulnerabilities (from time to time) that can put a system at risk. This can be easily tamed using community and commercial tools that constantly check for vulnerabilities and warn (locally or at GitHub), some can even patch them immediately

**Otherwise:** Keeping your code clean from vulnerabilities without dedicated tools will require you to constantly follow online publications about new threats. Quite tedious

🔗 [**Read More: Use tools that automatically detect vulnerabilities**](./sections/production/detectvulnerabilities.md)

<br/><br/>

## ![✔] 5.14. Assign a transaction id to each log statement

**TL;DR:** Assign the same identifier, transaction-id: uuid(), to each log entry within a single request (also known as correlation-id/tracing-id/request-context). Then when inspecting errors in logs, easily conclude what happened before and after. Node has a built-in mechanism, [AsyncLocalStorage](https://nodejs.org/api/async_context.html), for keeping the same context across asynchronous calls. see code examples inside

**Otherwise:** Looking at a production error log without the context – what happened before – makes it much harder and slower to reason about the issue

🔗 [**Read More: Assign ‘TransactionId’ to each log statement**](./sections/production/assigntransactionid.md)

<br/><br/>

## ![✔] 5.15. Set `NODE_ENV=production`

**TL;DR:** Set the environment variable `NODE_ENV` to ‘production’ or ‘development’ to flag whether production optimizations should get activated – some npm packages determine the current environment and optimize their code for production

**Otherwise:** Omitting this simple property might greatly degrade performance when dealing with some specific libraries like Express server-side rendering

🔗 [**Read More: Set NODE_ENV=production**](./sections/production/setnodeenv.md)

<br/><br/>

## ![✔] 5.16. Design automated, atomic and zero-downtime deployments

**TL;DR:** Research shows that teams who perform many deployments lower the probability of severe production issues. Fast and automated deployments that don’t require risky manual steps and service downtime significantly improve the deployment process. You should probably achieve this using Docker combined with CI tools as they became the industry standard for streamlined deployment

**Otherwise:** Long deployments -> production downtime & human-related error -> team unconfident in making deployment -> fewer deployments and features

<br/><br/>

## ![✔] 5.17. Use an LTS release of Node.js

**TL;DR:** Ensure you are using an LTS version of Node.js to receive critical bug fixes, security updates and performance improvements

**Otherwise:** Newly discovered bugs or vulnerabilities could be used to exploit an application running in production, and your application may become unsupported by various modules and harder to maintain

🔗 [**Read More: Use an LTS release of Node.js**](./sections/production/LTSrelease.md)

<br/><br/>

## ![✔] 5.18. Log to stdout, avoid specifying log destination within the app

### `📝 #updated`

**TL;DR:** Log destinations should not be hard-coded by developers within the application code, but instead should be defined by the execution environment the application runs in. Developers should write logs to `stdout` using a logger utility and then let the execution environment (container, server, etc.) pipe the `stdout` stream to the appropriate destination (i.e. Splunk, Graylog, ElasticSearch, etc.).

**Otherwise:** If developers set the log routing, less flexibility is left for the ops professional who wishes to customize it. Beyond this, if the app tries to log directly to a remote location (e.g., Elastic Search), in case of panic or crash - further logs that might explain the problem won't arrive

🔗 [**Read More: Log Routing**](./sections/production/logrouting.md)

<br/><br/>

## ![✔] 5.19. Install your packages with `npm ci`

**TL;DR:** Run `npm ci` to strictly do a clean install of your dependencies matching package.json and package-lock.json. Obviously production code must use the exact version of the packages that were used for testing. While package-lock.json file sets strict version for dependencies, in case of mismatch with the file package.json, the command 'npm install' will treat package.json as the source of truth. On the other hand, the command 'npm ci' will exit with error in case of mismatch between these files

**Otherwise:** QA will thoroughly test the code and approve a version that will behave differently in production. Even worse, different servers in the same production cluster might run different code.

🔗 [**Read More: Use npm ci**](./sections/production/installpackageswithnpmci.md)

<br/><br/><br/>

<p align="right"><a href="#table-of-contents">⬆ Return to top</a></p>

# `6. Security Best Practices`

<div align="center">
<img src="https://img.shields.io/badge/OWASP%20Threats-Top%2010-green.svg" alt="54 items"/>
</div>

## ![✔] 6.1. Embrace linter security rules

<a href="https://www.owasp.org/index.php/Top_10-2017_A1-Injection" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A1:Injection%20-green.svg" alt=""/></a> <a href="https://www.owasp.org/index.php/Top_10-2017_A7-Cross-Site_Scripting_(XSS)" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20XSS%20-green.svg" alt=""/></a>

**TL;DR:** Make use of security-related linter plugins such as [eslint-plugin-security](https://github.com/nodesecurity/eslint-plugin-security) to catch security vulnerabilities and issues as early as possible, preferably while they're being coded. This can help catching security weaknesses like using eval, invoking a child process or importing a module with a string literal (e.g. user input). Click 'Read more' below to see code examples that will get caught by a security linter

**Otherwise:** What could have been a straightforward security weakness during development becomes a major issue in production. Also, the project may not follow consistent code security practices, leading to vulnerabilities being introduced, or sensitive secrets committed into remote repositories

🔗 [**Read More: Lint rules**](./sections/security/lintrules.md)

<br/><br/>

## ![✔] 6.2. Limit concurrent requests using a middleware

<a href="https://www.owasp.org/index.php/Denial_of_Service" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20DDOS%20-green.svg" alt=""/></a>

**TL;DR:** DOS attacks are very popular and relatively easy to conduct. Implement rate limiting using an external service such as cloud load balancers, cloud firewalls, nginx, [rate-limiter-flexible](https://www.npmjs.com/package/rate-limiter-flexible) package, or (for smaller and less critical apps) a rate-limiting middleware (e.g. [express-rate-limit](https://www.npmjs.com/package/express-rate-limit))

**Otherwise:** An application could be subject to an attack resulting in a denial of service where real users receive a degraded or unavailable service.

🔗 [**Read More: Implement rate limiting**](./sections/security/limitrequests.md)

<br/><br/>

## ![✔] 6.3 Extract secrets from config files or use packages to encrypt them

<a href="https://www.owasp.org/index.php/Top_10-2017_A6-Security_Misconfiguration" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A6:Security%20Misconfiguration%20-green.svg" alt=""/></a> <a href="https://www.owasp.org/index.php/Top_10-2017_A3-Sensitive_Data_Exposure" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A3:Sensitive%20Data%20Exposure%20-green.svg" alt=""/></a>

**TL;DR:** Never store plain-text secrets in configuration files or source code. Instead, make use of secret-management systems like Vault products, Kubernetes/Docker Secrets, or using environment variables. As a last resort, secrets stored in source control must be encrypted and managed (rolling keys, expiring, auditing, etc). Make use of pre-commit/push hooks to prevent committing secrets accidentally

**Otherwise:** Source control, even for private repositories, can mistakenly be made public, at which point all secrets are exposed. Access to source control for an external party will inadvertently provide access to related systems (databases, apis, services, etc).

🔗 [**Read More: Secret management**](./sections/security/secretmanagement.md)

<br/><br/>

## ![✔] 6.4. Prevent query injection vulnerabilities with ORM/ODM libraries

<a href="https://www.owasp.org/index.php/Top_10-2017_A1-Injection" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A1:Injection%20-green.svg" alt=""/></a>

**TL;DR:** To prevent SQL/NoSQL injection and other malicious attacks, always make use of an ORM/ODM or a database library that escapes data or supports named or indexed parameterized queries, and takes care of validating user input for expected types. Never just use JavaScript template strings or string concatenation to inject values into queries as this opens your application to a wide spectrum of vulnerabilities. All the reputable Node.js data access libraries (e.g. [Sequelize](https://github.com/sequelize/sequelize), [Knex](https://github.com/tgriesser/knex), [mongoose](https://github.com/Automattic/mongoose)) have built-in protection against injection attacks.

**Otherwise:** Unvalidated or unsanitized user input could lead to operator injection when working with MongoDB for NoSQL, and not using a proper sanitization system or ORM will easily allow SQL injection attacks, creating a giant vulnerability.

🔗 [**Read More: Query injection prevention using ORM/ODM libraries**](./sections/security/ormodmusage.md)

<br/><br/>

## ![✔] 6.5. Collection of generic security best practices

**TL;DR:** This is a collection of security advice that is not related directly to Node.js - the Node implementation is not much different than any other language. Click read more to skim through.

🔗 [**Read More: Common security best practices**](./sections/security/commonsecuritybestpractices.md)

<br/><br/>

## ![✔] 6.6. Adjust the HTTP response headers for enhanced security

<a href="https://www.owasp.org/index.php/Top_10-2017_A6-Security_Misconfiguration" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A6:Security%20Misconfiguration%20-green.svg" alt=""/></a>

**TL;DR:** Your application should be using secure headers to prevent attackers from using common attacks like cross-site scripting (XSS), clickjacking and other malicious attacks. These can be configured easily using modules like [helmet](https://www.npmjs.com/package/helmet).

**Otherwise:** Attackers could perform direct attacks on your application's users, leading to huge security vulnerabilities

🔗 [**Read More: Using secure headers in your application**](./sections/security/secureheaders.md)

<br/><br/>

## ![✔] 6.7. Constantly and automatically inspect for vulnerable dependencies

<a href="https://www.owasp.org/index.php/Top_10-2017_A9-Using_Components_with_Known_Vulnerabilities" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A9:Known%20Vulnerabilities%20-green.svg" alt=""/></a>

**TL;DR:** With the npm ecosystem it is common to have many dependencies for a project. Dependencies should always be kept in check as new vulnerabilities are found. Use tools like [npm audit](https://docs.npmjs.com/cli/audit) or [snyk](https://snyk.io/) to track, monitor and patch vulnerable dependencies. Integrate these tools with your CI setup so you catch a vulnerable dependency before it makes it to production.

**Otherwise:** An attacker could detect your web framework and attack all its known vulnerabilities.

🔗 [**Read More: Dependency security**](./sections/security/dependencysecurity.md)

<br/><br/>

## ![✔] 6.8. Protect Users' Passwords/Secrets using bcrypt or scrypt

<a href="https://www.owasp.org/index.php/Top_10-2017_A2-Broken_Authentication" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A9:Broken%20Authentication%20-green.svg" alt=""/></a>

**TL;DR:** Passwords or secrets (e.g. API keys) should be stored using a secure hash + salt function like `bcrypt`,`scrypt`, or worst case `pbkdf2`.

**Otherwise:** Passwords and secrets that are stored without using a secure function are vulnerable to brute forcing and dictionary attacks that will lead to their disclosure eventually.

🔗 [**Read More: User Passwords**](./sections/security/userpasswords.md)

<br/><br/>

## ![✔] 6.9. Escape HTML, JS and CSS output

<a href="https://www.owasp.org/index.php/Top_10-2017_A7-Cross-Site_Scripting_(XSS)" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A7:XSS%20-green.svg" alt=""/></a>

**TL;DR:** Untrusted data that is sent down to the browser might get executed instead of just being displayed, this is commonly referred as a cross-site-scripting (XSS) attack. Mitigate this by using dedicated libraries that explicitly mark the data as pure content that should never get executed (i.e. encoding, escaping)

**Otherwise:** An attacker might store malicious JavaScript code in your DB which will then be sent as-is to the poor clients

🔗 [**Read More: Escape output**](./sections/security/escape-output.md)

<br/><br/>

## ![✔] 6.10. Validate incoming JSON schemas

<a href="https://www.owasp.org/index.php/Top_10-2017_A7-Cross-Site_Scripting_(XSS)" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A7: XSS%20-green.svg" alt=""/></a> <a href="https://www.owasp.org/index.php/Top_10-2017_A8-Insecure_Deserialization" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A8:Insecured%20Deserialization%20-green.svg" alt=""/></a>

**TL;DR:** Validate the incoming requests' body payload and ensure it meets expectations, fail fast if it doesn't. To avoid tedious validation coding within each route you may use lightweight JSON-based validation schemas such as [jsonschema](https://www.npmjs.com/package/jsonschema) or [joi](https://www.npmjs.com/package/joi)

**Otherwise:** Your generosity and permissive approach greatly increases the attack surface and encourages the attacker to try out many inputs until they find some combination to crash the application

🔗 [**Read More: Validate incoming JSON schemas**](./sections/security/validation.md)

<br/><br/>

## ![✔] 6.11. Support blocklisting JWTs

<a href="https://www.owasp.org/index.php/Top_10-2017_A2-Broken_Authentication" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A9:Broken%20Authentication%20-green.svg" alt=""/></a>

**TL;DR:** When using JSON Web Tokens (for example, with [Passport.js](https://github.com/jaredhanson/passport)), by default there's no mechanism to revoke access from issued tokens. Once you discover some malicious user activity, there's no way to stop them from accessing the system as long as they hold a valid token. Mitigate this by implementing a blocklist of untrusted tokens that are validated on each request.

**Otherwise:** Expired, or misplaced tokens could be used maliciously by a third party to access an application and impersonate the owner of the token.

🔗 [**Read More: Blocklist JSON Web Tokens**](./sections/security/expirejwt.md)

<br/><br/>

## ![✔] 6.12. Prevent brute-force attacks against authorization

<a href="https://www.owasp.org/index.php/Top_10-2017_A2-Broken_Authentication" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A9:Broken%20Authentication%20-green.svg" alt=""/></a>

**TL;DR:** A simple and powerful technique is to limit authorization attempts using two metrics:

1. The first is number of consecutive failed attempts by the same user unique ID/name and IP address.
2. The second is number of failed attempts from an IP address over some long period of time. For example, block an IP address if it makes 100 failed attempts in one day.

**Otherwise:** An attacker can issue unlimited automated password attempts to gain access to privileged accounts on an application

🔗 [**Read More: Login rate limiting**](./sections/security/login-rate-limit.md)

<br/><br/>

## ![✔] 6.13. Run Node.js as non-root user

<a href="https://www.owasp.org/index.php/Top_10-2017_A5-Broken_Access_Control" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A5:Broken%20Access%20Access%20Control-green.svg" alt=""/></a>

**TL;DR:** There is a common scenario where Node.js runs as a root user with unlimited permissions. For example, this is the default behaviour in Docker containers. It's recommended to create a non-root user and either bake it into the Docker image (examples given below) or run the process on this user's behalf by invoking the container with the flag "-u username"

**Otherwise:** An attacker who manages to run a script on the server gets unlimited power over the local machine (e.g. change iptable and re-route traffic to their server)

🔗 [**Read More: Run Node.js as non-root user**](./sections/security/non-root-user.md)

<br/><br/>

## ![✔] 6.14. Limit payload size using a reverse-proxy or a middleware

<a href="https://www.owasp.org/index.php/Top_10-2017_A8-Insecure_Deserialization" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A8:Insecured%20Deserialization%20-green.svg" alt=""/></a> <a href="https://www.owasp.org/index.php/Top_10-2017_A1-Injection" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20DDOS%20-green.svg" alt=""/></a>

**TL;DR:** The bigger the body payload is, the harder your single thread works in processing it. This is an opportunity for attackers to bring servers to their knees without tremendous amount of requests (DOS/DDOS attacks). Mitigate this limiting the body size of incoming requests on the edge (e.g. firewall, ELB) or by configuring [express body parser](https://github.com/expressjs/body-parser) to accept only small-size payloads

**Otherwise:** Your application will have to deal with large requests, unable to process the other important work it has to accomplish, leading to performance implications and vulnerability towards DOS attacks

🔗 [**Read More: Limit payload size**](./sections/security/requestpayloadsizelimit.md)

<br/><br/>

## ![✔] 6.15. Avoid JavaScript eval statements

<a href="https://www.owasp.org/index.php/Top_10-2017_A7-Cross-Site_Scripting_(XSS)" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A7:XSS%20-green.svg" alt=""/></a> <a href="https://www.owasp.org/index.php/Top_10-2017_A1-Injection" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A1:Injection%20-green.svg" alt=""/></a> <a href="https://www.owasp.org/index.php/Top_10-2017_A4-XML_External_Entities_(XXE)" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A4:External%20Entities%20-green.svg" alt=""/></a>

**TL;DR:** `eval` is evil as it allows executing custom JavaScript code during run time. This is not just a performance concern but also an important security concern due to malicious JavaScript code that may be sourced from user input. Another language feature that should be avoided is `new Function` constructor. `setTimeout` and `setInterval` should never be passed dynamic JavaScript code either.

**Otherwise:** Malicious JavaScript code finds a way into text passed into `eval` or other real-time evaluating JavaScript language functions, and will gain complete access to JavaScript permissions on the page. This vulnerability is often manifested as an XSS attack.

🔗 [**Read More: Avoid JavaScript eval statements**](./sections/security/avoideval.md)

<br/><br/>

## ![✔] 6.16. Prevent evil RegEx from overloading your single thread execution

<a href="https://www.owasp.org/index.php/Denial_of_Service" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20DDOS%20-green.svg" alt=""/></a>

**TL;DR:** Regular Expressions, while being handy, pose a real threat to JavaScript applications at large, and the Node.js platform in particular. A user input for text to match might require an outstanding amount of CPU cycles to process. RegEx processing might be inefficient to an extent that a single request that validates 10 words can block the entire event loop for 6 seconds and set the CPU on 🔥. For that reason, prefer third-party validation packages like [validator.js](https://github.com/chriso/validator.js) instead of writing your own Regex patterns, or make use of [safe-regex](https://github.com/substack/safe-regex) to detect vulnerable regex patterns

**Otherwise:** Poorly written regexes could be susceptible to Regular Expression DoS attacks that will block the event loop completely. For example, the popular `moment` package was found vulnerable with malicious RegEx usage in November of 2017

🔗 [**Read More: Prevent malicious RegEx**](./sections/security/regex.md)

<br/><br/>

## ![✔] 6.17. Avoid module loading using a variable

<a href="https://www.owasp.org/index.php/Top_10-2017_A7-Cross-Site_Scripting_(XSS)" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A7:XSS%20-green.svg" alt=""/></a> <a href="https://www.owasp.org/index.php/Top_10-2017_A1-Injection" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A1:Injection%20-green.svg" alt=""/></a> <a href="https://www.owasp.org/index.php/Top_10-2017_A4-XML_External_Entities_(XXE)" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A4:External%20Entities%20-green.svg" alt=""/></a>

**TL;DR:** Avoid requiring/importing another file with a path that was given as parameter due to the concern that it could have originated from user input. This rule can be extended for accessing files in general (i.e. `fs.readFile()`) or other sensitive resource access with dynamic variables originating from user input. [Eslint-plugin-security](https://www.npmjs.com/package/eslint-plugin-security) linter can catch such patterns and warn early enough

**Otherwise:** Malicious user input could find its way to a parameter that is used to require tampered files, for example, a previously uploaded file on the file system, or access already existing system files.

🔗 [**Read More: Safe module loading**](./sections/security/safemoduleloading.md)

<br/><br/>

## ![✔] 6.18. Run unsafe code in a sandbox

<a href="https://www.owasp.org/index.php/Top_10-2017_A7-Cross-Site_Scripting_(XSS)" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A7:XSS%20-green.svg" alt=""/></a> <a href="https://www.owasp.org/index.php/Top_10-2017_A1-Injection" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A1:Injection%20-green.svg" alt=""/></a> <a href="https://www.owasp.org/index.php/Top_10-2017_A4-XML_External_Entities_(XXE)" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A4:External%20Entities%20-green.svg" alt=""/></a>

**TL;DR:** When tasked to run external code that is given at run-time (e.g. plugin), use any sort of 'sandbox' execution environment that isolates and guards the main code against the plugin. This can be achieved using a dedicated process (e.g. `cluster.fork()`), serverless environment or dedicated npm packages that act as a sandbox

**Otherwise:** A plugin can attack through an endless variety of options like infinite loops, memory overloading, and access to sensitive process environment variables

🔗 [**Read More: Run unsafe code in a sandbox**](./sections/security/sandbox.md)

<br/><br/>

## ![✔] 6.19. Take extra care when working with child processes

<a href="https://www.owasp.org/index.php/Top_10-2017_A7-Cross-Site_Scripting_(XSS)" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A7:XSS%20-green.svg" alt=""/></a> <a href="https://www.owasp.org/index.php/Top_10-2017_A1-Injection" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A1:Injection%20-green.svg" alt=""/></a> <a href="https://www.owasp.org/index.php/Top_10-2017_A4-XML_External_Entities_(XXE)" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A4:External%20Entities%20-green.svg" alt=""/></a>

**TL;DR:** Avoid using child processes when possible and validate and sanitize input to mitigate shell injection attacks if you still have to. Prefer using `child_process.execFile` which by definition will only execute a single command with a set of attributes and will not allow shell parameter expansion.

**Otherwise:** Naive use of child processes could result in remote command execution or shell injection attacks due to malicious user input passed to an unsanitized system command.

🔗 [**Read More: Be cautious when working with child processes**](./sections/security/childprocesses.md)

<br/><br/>

## ![✔] 6.20. Hide error details from clients

<a href="https://www.owasp.org/index.php/Top_10-2017_A6-Security_Misconfiguration" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A6:Security%20Misconfiguration%20-green.svg" alt=""/></a>

**TL;DR:** An integrated express error handler hides the error details by default. However, great are the chances that you implement your own error handling logic with custom Error objects (considered by many as a best practice). If you do so, ensure not to return the entire Error object to the client, which might contain some sensitive application details

**Otherwise:** Sensitive application details such as server file paths, third party modules in use, and other internal workflows of the application which could be exploited by an attacker, could be leaked from information found in a stack trace

🔗 [**Read More: Hide error details from client**](./sections/security/hideerrors.md)

<br/><br/>

## ![✔] 6.21. Configure 2FA for npm or Yarn

<a href="https://www.owasp.org/index.php/Top_10-2017_A6-Security_Misconfiguration" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A6:Security%20Misconfiguration%20-green.svg" alt=""/></a>

**TL;DR:** Any step in the development chain should be protected with MFA (multi-factor authentication), npm/Yarn are a sweet opportunity for attackers who can get their hands on some developer's password. Using developer credentials, attackers can inject malicious code into libraries that are widely installed across projects and services. Maybe even across the web if published in public. Enabling 2-factor-authentication in npm leaves almost zero chances for attackers to alter your package code.

**Otherwise:** [Have you heard about the eslint developer whose password was hijacked?](https://medium.com/@oprearocks/eslint-backdoor-what-it-is-and-how-to-fix-the-issue-221f58f1a8c8)

<br/><br/>

## ![✔] 6.22. Modify session middleware settings

<a href="https://www.owasp.org/index.php/Top_10-2017_A6-Security_Misconfiguration" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A6:Security%20Misconfiguration%20-green.svg" alt=""/></a>

**TL;DR:** Each web framework and technology has its known weaknesses - telling an attacker which web framework we use is a great help for them. Using the default settings for session middlewares can expose your app to module- and framework-specific hijacking attacks in a similar way to the `X-Powered-By` header. Try hiding anything that identifies and reveals your tech stack (E.g. Node.js, express)

**Otherwise:** Cookies could be sent over insecure connections, and an attacker might use session identification to identify the underlying framework of the web application, as well as module-specific vulnerabilities

🔗 [**Read More: Cookie and session security**](./sections/security/sessions.md)

<br/><br/>

## ![✔] 6.23. Avoid DOS attacks by explicitly setting when a process should crash

<a href="https://www.owasp.org/index.php/Denial_of_Service" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20DDOS%20-green.svg" alt=""/></a>

**TL;DR:** The Node process will crash when errors are not handled. Many best practices even recommend to exit even though an error was caught and got handled. Express, for example, will crash on any asynchronous error - unless you wrap routes with a catch clause. This opens a very sweet attack spot for attackers who recognize what input makes the process crash and repeatedly send the same request. There's no instant remedy for this but a few techniques can mitigate the pain: Alert with critical severity anytime a process crashes due to an unhandled error, validate the input and avoid crashing the process due to invalid user input, wrap all routes with a catch and consider not to crash when an error originated within a request (as opposed to what happens globally)

**Otherwise:** This is just an educated guess: given many Node.js applications, if we try passing an empty JSON body to all POST requests - a handful of applications will crash. At that point, we can just repeat sending the same request to take down the applications with ease

<br/><br/>

## ![✔] 6.24. Prevent unsafe redirects

<a href="https://www.owasp.org/index.php/Top_10-2017_A1-Injection" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A1:Injection%20-green.svg" alt=""/></a>

**TL;DR:** Redirects that do not validate user input can enable attackers to launch phishing scams, steal user credentials, and perform other malicious actions.

**Otherwise:** If an attacker discovers that you are not validating external, user-supplied input, they may exploit this vulnerability by posting specially-crafted links on forums, social media, and other public places to get users to click it.

🔗 [**Read More: Prevent unsafe redirects**](./sections/security/saferedirects.md)

<br/><br/>

## ![✔] 6.25. Avoid publishing secrets to the npm registry

<a href="https://www.owasp.org/index.php/Top_10-2017_A6-Security_Misconfiguration" target="_blank"><img src="https://img.shields.io/badge/%E2%9C%94%20OWASP%20Threats%20-%20A6:Security%20Misconfiguration%20-green.svg" alt=""/></a>

**TL;DR:** Precautions should be taken to avoid the risk of accidentally publishing secrets to public npm registries. An `.npmignore` file can be used to ignore specific files or folders, or the `files` array in `package.json` can act as an allow list.

**Otherwise:** Your project's API keys, passwords or other secrets are open to be abused by anyone who comes across them, which may result in financial loss, impersonation, and other risks.

🔗 [**Read More: Avoid publishing secrets**](./sections/security/avoid_publishing_secrets.md)

<br/><br/>

## ![✔] 6.26 Inspect for outdated packages

**TL;DR:** Use your preferred tool (e.g. `npm outdated` or [npm-check-updates](https://www.npmjs.com/package/npm-check-updates)) to detect installed outdated packages, inject this check into your CI pipeline and even make a build fail in a severe scenario. For example, a severe scenario might be when an installed package is 5 patch commits behind (e.g. local version is 1.3.1 and repository version is 1.3.8) or it is tagged as deprecated by its author - kill the build and prevent deploying this version

**Otherwise:** Your production will run packages that have been explicitly tagged by their author as risky

<br/><br/>

## ![✔] 6.27. Import built-in modules using the 'node:' protocol

### `🌟 #new`

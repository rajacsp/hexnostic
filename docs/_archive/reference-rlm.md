Here is the markdown transcription of the paper "Recursive Language Models".

# Recursive Language Models

**Alex L. Zhang** $^1$ **Tim Kraska** $^1$ **Omar Khattab** $^1$

$^1$MIT CSAIL, Cambridge, MA, USA. Correspondence to: Alex L. Zhang, Omar Khattab `<altzhang@mit.edu, okhattab@mit.edu>`.

*Preprint. January 29, 2026.*

## Abstract
We study allowing large language models (LLMs) to process arbitrarily long prompts through the lens of inference-time scaling. We propose **Recursive Language Models (RLMs)**, a general inference paradigm that treats long prompts as part of an external *environment* and allows the LLM to *programmatically examine, decompose, and recursively call itself over snippets of the prompt*. We find that RLMs can successfully process inputs up to two orders of magnitude beyond model context windows and, even for shorter prompts, dramatically outperform the quality of vanilla frontier LLMs and common long-context scaffolds across four diverse long-context tasks while having comparable cost. At a small scale, we post-train the first natively recursive language model. Our model, **RLM-Qwen3-8B**, outperforms the underlying Qwen3-8B model by 28.3% on average and even approaches the quality of vanilla GPT-5 on three long-context tasks. Code is available at [https://github.com/alexzhang13/rlm](https://github.com/alexzhang13/rlm).

---

[**Figure 1 Description:** Three line charts comparing GPT-5 and RLM(GPT-5) performance across increasing input context lengths (log scale from $2^{13}$ to $2^{18}$ tokens/approx 8k to 1M).
*   **Top (S-NIAH):** Both models perform perfectly (100%) up to the red vertical line (GPT-5 context limit). Beyond the limit, GPT-5 drops to 0, while RLM maintains 100%.
*   **Middle (OOLONG):** GPT-5 performance degrades steadily as context length increases, dropping significantly before the context limit. RLM maintains a score around 60-80% throughout the entire range, significantly outperforming GPT-5.
*   **Bottom (OOLONG-Pairs):** A highly complex task. GPT-5 performance is near zero for most lengths. RLM maintains scores between 60-80% across the full context range.
*   **Key Insight:** GPT-5 degrades with length and task complexity (context rot). RLM maintains performance even beyond the 272K token context window of GPT-5 (marked by the red region).]

---

## 1. Introduction

Frontier reasoning models have limited context windows and, even within their limits, tend to exhibit *context rot* (Hong et al., 2025), a phenomenon illustrated in Figure 1 where quality degrades steeply as prompts get longer. Though we expect context lengths to steadily rise through improvements to training, architecture, and infrastructure, we are interested in *whether it is possible to scale the context size of general-purpose LLMs by orders of magnitude*. This is increasingly urgent as LLMs begin to be widely adopted for long-horizon tasks, in which they must routinely process tens if not hundreds of millions of tokens.

We study this question through the lens of scaling inference-time compute. We are inspired by the way that *reasoning models* have become the fundamental interface to LLMs, resulting not only in empirical gains but also additional theoretical expressive power (Merrill & Sabharwal, 2024) compared to vanilla Transformers. Though most inference-time methods for dealing with long context are task-specific (Wu et al., 2021; Chang et al., 2024), the most popular general approach is *context condensation or compaction* (Khattab et al., 2021; Smith, 2025; OpenAI, 2025b; Wu et al., 2025), where context from user requests or agent trajectories is repeatedly summarized once it exceeds a length threshold. Unfortunately, compaction is rarely expressive enough for tasks that require dense access throughout the prompt. It presumes that *some* details that appear early in the prompt can safely be forgotten to make room for new content.

We introduce **Recursive Language Models (RLMs)**, a general-purpose inference paradigm for dramatically scaling the effective input and output lengths of LLMs. The key insight is that arbitrarily long user prompts should not be fed into the neural network (e.g., Transformer) directly but should instead be treated as *part of the environment that the LLM is tasked to symbolically and recursively interact with*.

[**Figure 2 Description:** A diagram illustrating the RLM architecture.
1.  **Input:** An extremely long prompt (e.g., a book or large codebase).
2.  **Environment:** The prompt is loaded as a variable (e.g., `prompt`) inside a Python REPL environment $\mathcal{E}$, rather than fed to the model context.
3.  **RLM Loop:** The root LLM receives a system prompt and metadata about the environment.
4.  **Interaction:** The LLM writes code to inspect the `prompt` variable (e.g., `prompt[:100]`), decompose it (e.g., `split('Chapter 2')`), and run sub-queries.
5.  **Recursion:** The code can invoke `llm_query()` on snippets of the prompt. These are "Sub-RLMs" (depth=1).
6.  **Output:** The LLM iterates until it produces a `Final Response`.
*Example Code shown in diagram:* `part1, part2 = prompt.split('Chapter 2'); pre_cat = llm_query(f"In Chapter 1, find... {part1}"); print(FINAL_ANSWER)`.]

As Figure 2 shows, an RLM exposes the same external interface as an LLM or a reasoning model: it accepts a string prompt of arbitrary structure and produces a string response. Given a prompt $P$, the RLM initializes a Read-Eval-Print Loop (REPL) programming environment in which $P$ is set as the value of a variable. It then offers the LLM general context about the REPL environment (e.g., the length of the string $P$), and permits it to write code that peeks into and decomposes $P$, and to iteratively observe any side effects from execution. Crucially, RLMs encourage the LLM to understand, transform, and execute the input prompt by *writing symbolic programs that invoke the LLM itself* on as many slices of the input as necessary.

By treating the prompt itself as an external object and enabling symbolic recursion, RLMs tackle limitations of expressive power in recent work on coding agents, retrieval agents, and sub-agent delegation. In particular, prior coding agents and retrieval agents treat some designated external data source (e.g., a filesystem or a corpus of search documents) as an environment for fetching snippets. However, *they can only fill up the underlying LLM's context window with snippets before breaking down*. Similarly, prior self-delegation approaches (Anthropic, 2025; Sentient AI, 2025; Schroeder et al., 2025; Sun et al., 2025) allow LLMs to invoke themselves as sub-agents. However, they *are handicapped by the underlying LLM's limited output lengths* because they are designed to verbalize sub-calls autoregressively rather than producing them programmatically.

We evaluate RLMs using a frontier closed model (GPT-5; Singh et al. 2025) and a frontier open model (Qwen3-Coder-480B-A35B; Qwen Team 2025b) across four tasks with varying levels of complexity: deep research (Chen et al., 2025), information aggregation (Bertsch et al., 2025), code repository understanding (Bai et al., 2025), and a synthetic pairwise reasoning task where even frontier models fail catastrophically. We compare RLMs against direct LLM calls as well as context compaction, retrieval tool-use agents, and code-generation agents.

We find that RLMs demonstrate extremely strong performance even at the 10M+ token scale, and substantially outperform all other approaches at long-context processing, in many cases by double-digit percentage gains while maintaining comparable cost. In particular, as demonstrated in Figure 1, RLMs exhibit far less severe degradation for longer contexts and more sophisticated tasks.

Finally, at a small scale, we post-train the first natively recursive language model, demonstrating that RLMs can be improved quickly with little additional training. While a small open model (Qwen3-8B; Yang et al. 2025) struggles to solve long context tasks even in an RLM scaffold, our simple general-purpose training recipe uses only 1,000 samples from unrelated domains to improve its performance by a median of 28.3% across the four evaluation tasks.

## 2. Recursive Language Models

Given a base neural language model $\mathcal{M}$ with maximum context size $K$, a Recursive Language Model (RLM) is an inference-time scaffold around $\mathcal{M}$ that treats the user prompt as part of the environment without giving up the ability to densely process its content through different calls to $\mathcal{M}$. Given an arbitrary-length prompt string $P \in \Sigma^\star$, an RLM interacts with a persistent external environment $\mathcal{E}$ and returns a response string $Y \in \Sigma^\star$ (Figure 2). We would like *effectively unbounded input tokens* ($|P| \gg K$), *unbounded output tokens*, and an *unbounded semantic horizon*, e.g. the ability to do $\Omega(|P|)$ or $\Omega(|P|^2)$ semantic work.

Algorithm 1 describes how an RLM achieves this. Given a prompt $P$, the RLM initializes a persistent REPL programming environment with a variable containing the user prompt as a string and a function for invoking a sub-RLM with a new prompt. Then, it starts the RLM loop. In the first iteration, the algorithm invokes the *root neural model* $\mathcal{M}$ with only (constant-size) metadata about the user prompt, like its length, a short prefix, and how to access parts of it.

The root is instructed via prompting (Appendix C) and/or fine-tuning (Appendix A) to operate like an RLM: that is, *to generate code that helps it understand and transform its parts of its prompt $P$, and to build up intermediate values and the final response into new variables, potentially by invoking the sub-RLM within loops*. In Section 4, we find that existing LLMs can be prompted to do this and that training an 8B model to be natively recursive is promising.

Each iteration of the RLM loop executes code in the REPL, updates REPL state (intermediate variables), and collects in `stdout` any printed text. Only (constant-size) metadata about `stdout`, like a short prefix and length, is appended to $\mathcal{M}$'s history for the next iteration. $^1$ Once the RLM sets the variable `Final` inside the REPL, iteration stops and the value in `Final` is returned as the response.

$^1$ This is key: it forces $\mathcal{M}$ to rely on variables and sub-calls to manage long strings instead of polluting its window. In principle, if we trim each turn to $c$ tokens, we will have at most $K/c$ root iterations, each of which can launch arbitrarily many sub-calls. This is not a fundamental limitation, e.g. one could move the root horizon itself into a variable, but we typically want to limit the iterations at any level of recursion irrespective.

**Algorithm 1** A recursive language model, around LLM $\mathcal{M}$
```python
Input: prompt P
Output: response Y
state ← InitREPL(prompt=P)
state ← AddFunction(state, sub_RLM_M)
hist ← [Metadata(state)]
while True do
    code ← LLM_M(hist)
    (state, stdout) ← REPL(state, code)
    hist ← hist ∥ code ∥ Metadata(stdout)
    if state[Final] is set then
        return state[Final]
```

RLMs make three simple design choices that are missing from existing scaffolds. To highlight these, we include Algorithm 2 to illustrate a deceptively "similar" algorithm that is far less expressive. Both algorithms support some notion of sub-calls, external objects, and code execution, but they differ in terms of where the prompt and intermediate values live and where recursion occurs.

**Algorithm 2** Alternate scaffold with standard (poor) design choices for prompts, sub-calls, and code execution
```python
Input: prompt P
Output: response Y
actions ← {Finish, Exec, Search, sub_LLM_M}
hist ← [Metadata(actions), P]  // Flaw #1
while True do
    (action, val) ← LLM_M(hist)
    if action is Finish then
        return val                  // Flaw #2
    out ← RUN(action, val)          // Flaw #3
    hist ← hist ∥ (action, val, out)
    if Tok(hist) > K then
        hist ← Compact(hist)
```

First, an RLM must give the underlying LLM $\mathcal{M}$ a *symbolic handle* to the user prompt $P$, so the model can manipulate it without copying text into the root context window. Instead, ineffective Algorithm 2 starts by putting the user prompt $P$ into the LLM context window (`hist`) and thus inherits the window limitations of $\mathcal{M}$ and falls back to heuristics like context compaction. Even though the scaffold can access external data with, say, a `Search` action or filesystem access, it is fatally bounded with respect to user input.

Second, ineffective Algorithm 2 asks $\mathcal{M}$ to autoregressively generate the output directly, via a `Finish` action. This may seem innocuous, but it means that it also cannot generate longer outputs than the context window of $\mathcal{M}$ permits.

Third, and perhaps most importantly, an RLM requires *symbolic recursion*. That is, code running *inside* $\mathcal{E}$ must be able to invoke $\mathcal{M}$ on programmatically constructed transformations of $P$ (e.g., inside arbitrarily large loops), storing intermediate results symbolically. Though Algorithm 2 includes both a code execution action and a "sub-LLM" action separately, it is not able to invoke the sub-LLM programmatically and hence can only delegate a few *explicitly verbalized tasks* rather than writing short programs that can, say, loop over slices of the prompt and launch $\Omega(|P|)$ or even $\Omega(|P|^2)$ processes to understand or transform all parts of $P$.

## 3. Scaling Long Context Tasks

We hypothesize that the effective context window (Hsieh et al., 2024; Goldman et al., 2025; Hong et al., 2025) of an LLM cannot be understood independently of the *specific task*. That is, more "complex" problems will exhibit degradation at even *shorter lengths* than simpler ones. Because of this, we must characterize tasks in terms of how their *complexity scales with prompt length*.

For example, needle-in-a-haystack (NIAH) problems generally keep 'needles' constant as prompt length is scaled. As a result, frontier models can now reliably solve these tasks in RULER (Hsieh et al., 2024) in the 1M+ token settings but struggle at far shorter lengths on OOLONG (Bertsch et al., 2025), a task where the answer depends explicitly on almost every line in the prompt. $^2$

$^2$ This helps explain the patterns seen in Figure 1 earlier: GPT-5 scales effectively on the S-NIAH task, where the needle size is constant despite longer prompts, but shows faster degradation at increasingly *shorter* context lengths on the *linear*-complexity OOLONG and the *quadratic*-complexity OOLONG-Pairs.

### 3.1. Tasks

We design our evaluation around tasks where we can vary the lengths of the prompts, so we can consider problems whose difficulties scale differently with context length.

**S-NIAH.** Following the single needle-in-the-haystack task in RULER (Hsieh et al., 2024), we consider a set of 50 single tasks that require finding a specific phrase or number in a large set of unrelated text. Here, the information being sought scales as $O(1)$ with respect to input length.

**BrowseComp-Plus (1K documents)** (Chen et al., 2025). A multi-hop question-answering benchmark for DeepResearch (OpenAI, 2025a) questions that requires reasoning over multiple different documents. The benchmark provides a verified offline corpus that is guaranteed to contain gold, evidence, and hard negative documents for each question. Following Sun et al. (2025), we use 150 randomly sampled instances as our evaluation set; we provide 1000 randomly chosen documents as input, in which the gold and evidence documents are guaranteed to exist. We report the percentage of correct answers. The answer to each task requires piecing together information from several documents, making this harder than **S-NIAH** despite also requiring a constant number of documents.

**OOLONG** (Bertsch et al., 2025). A long reasoning benchmark that requires transforming chunks of the input semantically, then aggregating these chunks to form a final answer. We report scoring based on the original paper, which scores numerical answers as $score(\hat{y}) = 0.75^{|y-\hat{y}|}$ and other answers as exact match. We focus specifically on the `trec_coarse` split, a set of 50 tasks over a dataset of questions with semantic labels. Each task requires using nearly all entries of the dataset, and therefore scales linearly in processing complexity relative to the input length.

**OOLONG-Pairs.** We modify the `trec_coarse` split of OOLONG to include 20 new queries that specifically require aggregating *pairs* of chunks to construct the final answer. We report F1 scores over the answer. Each task requires using nearly all *pairs* of entries of the dataset, and therefore requires processing quadratically-many items relative to the input length. In Appendix D.1, we provide all queries in this benchmark.

**LongBench-v2 CodeQA** (Bai et al., 2025). A multi-choice code repository understanding split from LongBench-v2 that is challenging for modern frontier models. We report the score as the percentage of correct answers. Each instance requires reasoning over a fixed number of files in a codebase to find the right answer.

### 3.2. Methods and Baselines

We compare RLMs against commonly used task-agnostic inference methods, using two modern LMs, GPT-5 with medium reasoning (Singh et al., 2025) and default sampling parameters, and Qwen3-Coder-480B-A35B (Yang et al., 2025) using the sampling parameters described in Qwen Team (2025b). For Qwen3-Coder-480B-A35B, we compute costs based on the compute provider Fireworks (Fireworks AI, 2025). In addition to evaluating the base model on all tasks, we also evaluate the following methods and baselines:

**CodeAct (+ BM25).** We compare directly to a CodeAct (Wang et al., 2024) agent that can execute code inside of a ReAct (Yao et al., 2023) loop. Unlike an RLM, CodeAct does not offload the user prompt to the code environment, and instead provides it directly to the LM. Furthermore, following Jimenez et al. (2024); Chen et al. (2025), we equip this agent with a BM25 (Robertson & Zaragoza, 2009) retriever that indexes the input context for tasks where a retriever is appropriate.

**CodeAct with sub-calls.** To specifically ablate offloading the context as a variable in the REPL, we evaluate a CodeAct (Wang et al., 2024) baseline with the ability to invoke sub-LM calls. Compared to RLMs, this method loads the context directly into the model.

**Summary agent.** Following Sun et al. (2025); Wu et al. (2025); Yu et al. (2025), we consider an iterative agent that compacts the context as it is filled. For example, given a corpus of documents, it will iteratively accumulate the documents and summarize when full. In cases where a single document exceeds the model window, the agent will chunk it to fit within the model context window and invoke the same strategy over these chunks. For the GPT-5 experiments, due to the extremely high cost of applying this strategy to millions of tokens, we use GPT-5-nano for compaction and GPT-5 to provide the final answer.

**RLM with REPL.** We implement an RLM with a Python REPL environment, which loads a module for querying a sub-LM and uses a system prompt presented in Appendix C. For the GPT-5 experiments, we use GPT-5-mini for the recursive LMs and GPT-5 for the root LM, as we found this choice to strike a good balance between the capabilities of RLMs and the cost of the recursive calls. We notate a RLM using a model as RLM(model), e.g. RLM(GPT-5).

**RLM with REPL, no sub-calls.** We provide an ablation of our method, in which the prompt is loaded in a REPL environment without the ability to invoke sub-LM calls.

**Finetuning.** To create **RLM-Qwen3-8B**, we finetune Qwen3-8B on 1,000 filtered trajectories of Qwen3-Coder-480B-A35B as an RLM with Qwen3-8B sub-calls on LongBenchPro (Chen et al., 2026) tasks. We use sampling parameters described in Qwen Team (2025a), and evaluate the fine-tuned RLM-Qwen3-8B as an RLM on our long context tasks. The key insight for training is that being an effective sub-call model is roughly similar to being a general purpose reasoning model, so we can make the training much more tractable (and seemingly short-horizon) at small scale by focusing on improving the root model’s ability to manipulate the REPL and to launch recursive calls. We provide more training details in Appendix A.

## 4. Results and Discussion

Table 1 reports our main results. We additionally explore how vanilla frontier model performance and RLM performance degrades as input contexts grow in Figure 1.

**Observation 1: RLMs can scale to the 10M+ token regime and can outperform base LMs and existing task-agnostic agent scaffolds on long context tasks.** Across all tasks, RLMs demonstrate strong performance on prompts well beyond the effective context window of a frontier LM, performing base models and common long-context scaffolds by up to $2 \times$ the performance while maintaining comparable or cheaper average token costs. Notably, RLMs scale well beyond the base models' context window. For instance, on BrowseComp-Plus (1K), a linearly extrapolated cost for GPT-5-mini ingesting 6-11M input tokens is $\$1.50 - \$2.75$, while RLM(GPT-5) has an average cost of $\$0.99$ and outperforms both the summarization and retrieval baselines by over 29%.

**Table 1.** Performance comparison of different methods across long-context benchmarks of varying complexity. In gray is the average API cost $\pm$ the standard deviation of each method on each task. * indicates runs where a method (sometimes) ran into input context limits. Provider costs were computed under OpenAI for GPT-5 and Fireworks for other models. Non-zero scores are rounded to at least 0.1.

| Model | CodeQA | BrowseComp+ (1K) | OOLONG | OOLONG-Pairs |
| :--- | :---: | :---: | :---: | :---: |
| **Task Length $N$ (tokens)** | 23K-4.2M | 6M-11M | 131K | 32K |
| **GPT-5** (with RLM sub-calls to GPT-5-mini) | | | | |
| Base Model | 24.0* <span style="color:gray">($0.13 ± 0.07$)</span> | 0.0* <span style="color:gray">(N/A ± N/A)</span> | 44.0 <span style="color:gray">($0.14 ± 0.02$)</span> | 0.1 <span style="color:gray">($0.16 ± 0.10$)</span> |
| CodeAct (+ BM25) | 22.0* <span style="color:gray">($0.06 ± 0.08$)</span> | 51.0 <span style="color:gray">($0.71 ± 1.20$)</span> | 38.0 <span style="color:gray">($0.61 ± 1.06$)</span> | 24.7 <span style="color:gray">($0.75 ± 0.43$)</span> |
| CodeAct (+ sub-calls) | 24.0* <span style="color:gray">($0.06 ± 0.08$)</span> | 0.0* <span style="color:gray">(N/A ± N/A)</span> | 40.0 <span style="color:gray">($0.85 ± 1.27$)</span> | 28.4 <span style="color:gray">($1.11 ± 0.62$)</span> |
| Summary agent | 58.0 <span style="color:gray">($1.31 ± 1.46$)</span> | 70.5 <span style="color:gray">($0.57 ± 0.10$)</span> | 46.0 <span style="color:gray">($0.13 ± 0.01$)</span> | 0.1 <span style="color:gray">($0.13 ± 0.09$)</span> |
| **RLM** | **62.0** <span style="color:gray">($0.11 ± 0.10$)</span> | **91.3** <span style="color:gray">($0.99 ± 1.22$)</span> | **56.5** <span style="color:gray">($0.43 ± 0.85$)</span> | **58.0** <span style="color:gray">($0.33 ± 0.20$)</span> |
| RLM (no sub-calls) | 58.0 <span style="color:gray">($0.18 ± 0.56$)</span> | 88.0 <span style="color:gray">($0.44 ± 0.90$)</span> | 36.0 <span style="color:gray">($0.37 ± 0.42$)</span> | 43.9 <span style="color:gray">($0.69 ± 1.16$)</span> |
| **Qwen3-Coder-480B-A35B** | | | | |
| Base Model | 20.0* <span style="color:gray">($0.13 ± 0.08$)</span> | 0.0* <span style="color:gray">(N/A ± N/A)</span> | 36.0 <span style="color:gray">($0.06 ± 0.00$)</span> | 0.1 <span style="color:gray">($0.05 ± 0.01$)</span> |
| CodeAct (+ BM25) | 24.0* <span style="color:gray">($0.17 ± 0.08$)</span> | 12.7 <span style="color:gray">($0.39 ± 0.50$)</span> | 38.0 <span style="color:gray">($1.51 ± 1.09$)</span> | 0.3 <span style="color:gray">($1.54 ± 0.35$)</span> |
| CodeAct (+ sub-calls) | 26.0* <span style="color:gray">($0.28 ± 0.30$)</span> | 0.0* <span style="color:gray">(N/A ± N/A)</span> | 32.0 <span style="color:gray">($1.83 ± 1.14$)</span> | 0.1 <span style="color:gray">($1.49 ± 0.46$)</span> |
| Summary agent | 50.0 <span style="color:gray">($1.26 ± 1.50$)</span> | 38.0 <span style="color:gray">($8.98 ± 2.12$)</span> | 44.1 <span style="color:gray">($0.15 ± 0.01$)</span> | 0.31 <span style="color:gray">($0.05 ± 0.00$)</span> |
| RLM | 56.0 <span style="color:gray">($0.92 ± 1.23$)</span> | 44.7 <span style="color:gray">($0.84 ± 0.63$)</span> | **48.0** <span style="color:gray">($0.61 ± 0.49$)</span> | **23.1** <span style="color:gray">($1.02 ± 0.52$)</span> |
| RLM (no sub-calls) | **66.0** <span style="color:gray">($0.18 ± 0.58$)</span> | **46.0** <span style="color:gray">($0.82 ± 0.69$)</span> | 43.5 <span style="color:gray">($0.32 ± 0.13$)</span> | 17.3 <span style="color:gray">($1.77 ± 1.23$)</span> |
| **Qwen3-8B** | | | | |
| Base Model | 4.0* <span style="color:gray">($0.01 ± 0.00$)</span> | 0.0* <span style="color:gray">(N/A ± N/A)</span> | 0.0* <span style="color:gray">(N/A ± N/A)</span> | 0.1 <span style="color:gray">($0.01 ± 0.00$)</span> |
| RLM | 26.0 <span style="color:gray">($0.04 ± 0.13$)</span> | 2.0 <span style="color:gray">($0.03 ± 0.06$)</span> | 24.0 <span style="color:gray">($0.19 ± 0.26$)</span> | 4.3 <span style="color:gray">($0.05 ± 0.05$)</span> |
| RLM (fine-tuned) | **32.0** <span style="color:gray">($0.02 ± 0.02$)</span> | **14.0** <span style="color:gray">($0.01 ± 0.03$)</span> | **32.0** <span style="color:gray">($0.04 ± 0.09$)</span> | **5.2** <span style="color:gray">($0.02 ± 0.02$)</span> |

---

Furthermore, on tasks where processing costs scale with the input context, RLMs make significant improvements over the base model, even on tasks within the model's context window. On OOLONG, the RLM with GPT-5 and Qwen3-Coder outperform the base model by 28.4% and 33.3% respectively. On OOLONG-Pairs, both GPT-5 and Qwen3-Coder make little progress with F1 scores of <0.1%, while the RLM using these models achieve F1 scores of 58.0% and 23.1% respectively, highlighting the emergent capability of RLMs to handle extremely information-dense tasks.

**Observation 2: The REPL is necessary for handling long inputs, while the recursive sub-calling of RLMs provides strong benefits on information-dense inputs.** A key characteristic of RLMs is offloading the context as a variable in an environment $\mathcal{E}$ that the model can interact with. Even without sub-calling capabilities, our ablation of the RLM is able to scale beyond the context limit of the model and outperform other task-agnostic baselines on most long context settings. On the CodeQA and BrowseComp+ tasks with Qwen3-Coder, this ablation is able to outperform the RLM by 17.9% and 3% respectively.

On information-dense tasks like OOLONG or OOLONG-Pairs, we observed several cases where recursive LM sub-calling is necessary. In §4.1, we see RLM(Qwen3-Coder) perform the necessary semantic transformation line-by-line through recursive sub-calls, while the ablation without sub-calls is forced to use keyword heuristics to solve these tasks. Across all information-dense tasks, RLMs outperform the ablation without sub-calling by 10%-59%.

**Observation 3: LM performance degrades as a function of input length and problem complexity, while RLM performance scales better.** The benchmarks S-NIAH, OOLONG, and OOLONG-Pairs contain a fixed number of tasks over contexts with lengths ranging from $2^{13}$ to $2^{18}$. Each benchmark can be loosely categorized by different processing complexity of the input context with respect to length (roughly constant, linear, and quadratic respectively). In Figure 1, we directly compare an RLM using GPT-5 to base GPT-5 on each task. We find that GPT-5 performance degrades significantly faster for more complex tasks, while RLM performance degrades at a much slower rate, which aligns with the findings of Goldman et al. (2025). For context lengths beyond $2^{14}$, the RLM consistently outperforms GPT-5.

[**Figure 3 Description:** Bar charts showing the cost ($) of different methods at the 25th, 50th, 75th, and 95th percentiles.
*   **Left (GPT-5):** Base Model costs are low. RLM(GPT-5) costs are comparable to Base Model at 50th percentile but spike significantly at the 95th percentile (showing "long tail" trajectories). Summary Agent costs are consistently higher in upper percentiles.
*   **Right (Qwen3-Coder-480B):** Similar trend. RLM costs are moderate at median but high at the tail end.
*   **Takeaway:** RLMs have comparable costs for typical queries but can be expensive for outlier complex queries.]

Furthermore, RLM costs scale proportionally to the complexity of the task, while still remaining in the same order of magnitude of cost as GPT-5 (see Figure 11 in Appendix F). In §4.1, we explore the choices that the RLM makes that cause these differences in cost. Lastly, in this setting, we also observe that the base LM outperforms RLM in the small input context regime. By construction, a RLM has strictly more representation capacity than an LM. In practice, however, we observe that RLM performance is slightly worse on smaller input lengths, suggesting a tradeoff point between when to use a base LM and when to use an RLM.

**Observation 4: The inference cost of RLMs remains comparable to a base LM call but has high variance due to differences in trajectory lengths.** RLMs iteratively interact with their context until they find a suitable answer, leading to large differences in iteration length depending on task complexity. In Figure 3, we plot the quartile costs for each method across all experiments in Table 1 excluding BrowseComp-Plus (1K), as the base models cannot fit any of these tasks in context. For GPT-5, the median RLM run is cheaper than the median base model run, but many outlier RLM runs are significantly more expensive than any base model query. However, compared to the summarization agent which ingests the entire input context, RLMs are up to 3× cheaper while maintaining stronger performance across all tasks because the RLM is able to selectively view context.

We additionally report runtime numbers of each method in Figures 7, 8 in Appendix F, but we note several important caveats. Unlike API costs, these numbers are heavily dependent on implementation details such as the machine used, API request latency, and the asynchrony of LM calls. In our implementation of the baselines and RLMs, all LM calls are blocking / sequential. Nevertheless, similar to costs, we observe a wide range of runtimes, especially for RLMs.

**Observation 5: RLMs are a model-agnostic inference strategy, but different models exhibit different overall decisions on context management and sub-calling.** While GPT-5 and Qwen3-Coder-480B both exhibit strong performance as RLMs relative to their base model and other baselines, they also exhibit different performance and behavior across all tasks. On BrowseComp-Plus (1k) in particular, RLM(GPT-5) nearly solves all tasks while RLM(Qwen3-Coder) struggles to solve half.

We note that the RLM system prompt is fixed for each model across all experiments and is not tuned for any particular benchmark. Between GPT-5 and Qwen3-Coder, the only difference in the prompt is an extra line in the RLM(Qwen3-Coder) prompt warning against using too many sub-calls (see Appendix C). We provide an explicit example of this difference in example E.3, where RLM(Qwen3-Coder) launches a sub-call per line in OOLONG while GPT-5 is conservative about sub-querying LMs.

**Observation 6: Training RLMs on one domain can improve general downstream RLM performance.** Certain behavior in RLM trajectories are common among different domains, such as probing the input and recursively sub-calling on shorter contexts. In Table 1, we find that **RLM-Qwen3-8B**, a Qwen3-8B model that we fine-tuned on RLM(Qwen3-Coder-480B-A35B) trajectories on a small, *unrelated* set of tasks (LongBenchPro; Chen et al. 2026) considerably outperforms the base Qwen3-8B as an RLM by 28.3% on average. Furthermore, its inference costs are much lower due to better decision making and fewer mistakes as an RLM.

### 4.1. Emergent Patterns in RLM Trajectories

Even without explicit training, RLMs exhibit interesting context and problem decomposition behavior. We select several examples of snippets from RLM trajectories to understand how they solve long context problems and where they can improve. We discuss particular examples of interesting behavior here, with additional examples in Appendix E.

**Chunking and recursively sub-calling LMs.** RLMs defer essentially unbounded-length reasoning chains to sub-LM calls. The choice of decomposition can greatly affect task performance, especially for information-dense problems. In our experiments, we did not observe complicated partitioning strategies beyond uniform chunking or keyword searches. In Figure 4b, RLM(Qwen3-Coder) chunks by newline in a 1000+ line context from OOLONG.

**Filtering input information using code execution based on model priors.** A key intuition for why the RLM abstraction can maintain strong performance on huge inputs without exploding costs is the LM’s ability to filter input context without explicitly seeing it. Furthermore, model priors enable the RLM to narrow the search space and process fewer input tokens. As an example, in Figure 4a, we observed RLM(GPT-5) using `regex` queries to search for chunks containing keywords in the original prompt (e.g. "festival") and phrases it has a prior about (e.g. "La Union").

**Passing recursive LM outputs through variables for long output tasks.** RLMs are able to produce essentially unbounded tokens well beyond the limit of the base LM by returning variables in the REPL as output. Through the REPL, the RLM can iteratively construct these variables as a mixture of programmatic and sub-(R)LM output calls. We observed this strategy used heavily in OOLONG-Pairs trajectories, where the RLM stored the output of sub-LM calls over the input in variables and stitched them together to form a final answer (see Figure 4c).

## 5. Related Works

**Long-Context LM Systems.** There have primarily been two orthogonal directions for long-context management in language model systems: 1) directly changing the architecture of and retraining the base LM to handle longer contexts (Press et al., 2022; Gu et al., 2022; Munkhdalai et al., 2024), and 2) building a scaffold around the LM that implicitly handles the context – RLMs focus on the latter. One popular class of such strategies is *lossy* context management, which uses summarization or truncation to compress the input context at the cost of potentially losing fine-grained information. For example, MemWalker (Chen et al., 2023) constructs a tree-like data structure of the input that the LM can navigate when answering long context questions. ReSum (Wu et al., 2025) is another work that adds a summarization tool to periodically compress the context of a multi-turn agent. Another class of strategies implement an explicit memory hierarchy in the agent scaffold (Packer et al., 2024; Chhikara et al., 2025; Zhang et al., 2025). RLMs differ from these works in that all context window management is implicitly handled by the LM itself.

**Task Decomposition through sub-LM calls.** Many LM-based agents (Guo et al., 2024; Anthropic, 2025) use multiple, well-placed LM calls to solve a problem; however, many of these calls are placed based on human-engineered workflows. Several methods like ViperGPT (Surís et al., 2023), THREAD (Schroeder et al., 2025), DisCIPL (Grand et al., 2025), ReDel (Zhu et al., 2024), Context Folding (Sun et al., 2025), and AgentFold (Ye et al., 2025) have explored deferring the choice of sub-LM calls to the LM. These techniques emphasize *task* decomposition through recursive LM calls, but are unable to handle long context inputs beyond the length of the base LM. RLMs, on the other hand, are enabled by an extremely simple intuition (i.e., placing the prompt in the external environment) to *symbolically* manipulate arbitrarily long strings and to iteratively refine their recursion via execution feedback from the persistent REPL.

[**Figure 4 Description:** Three screenshots of code/REPL interactions illustrating RLM patterns.
*   **(a) Filtering:** Code that defines a `find_snippets` function using regex and keyword searches (`"dinengdeng"`, `"festival"`) to filter a large context window.
*   **(b) Decomposition:** Code that defines `process_batch` which splits questions and invokes `llm_query` on batches of items.
*   **(c) Stitching:** Code that takes outputs from previous steps (`formatted_pairs`), joins them into a large string `final_result`, and returns `FINAL_VAR(final_result)`.]

## 6. Limitations and Future Work

While RLMs show strong performance on tasks beyond the context window limitations of existing LMs at reasonable inference costs, evaluations for more difficult and natural long-context processing tasks and the best mechanisms for implementing RLMs both remain highly under-explored. We focused on synchronous sub-calls inside of a Python REPL environment, but we note that alternative strategies involving asynchronous sub-calls and sandboxed REPLs can potentially significantly reduce the runtime and inference cost of RLMs. Furthermore, we chose to use a max recursion depth of one (i.e. sub-calls are LMs); while we found strong performance on existing long-context benchmarks, we believe that future work should investigate deeper levels of recursion or even new hybrids between symbolic recursion and neural attention. We include additional limitations and negative results in Appendix B.

Lastly, we focused our experiments on evaluating RLMs using *existing* frontier models, but show initial evidence on a Qwen3-8B model that explicitly training a model to be used as a RLM provides very rapid performance improvements, even outside the training domain. We hypothesize that RLM trajectories can be viewed as a form of reasoning (OpenAI et al., 2024; DeepSeek-AI et al., 2025), which can be trained by bootstrapping existing models (Zelikman et al., 2022; 2024). We hope that training native RLMs can be treated as a new axis of scale to improve LM performance on general and long-horizon tasks.

## 7. Conclusion

We introduced Recursive Language Models (RLMs), a general inference framework for language models that offloads the input context and enables language models to recursively sub-query language models before providing an output. We explored an instantiation of this framework that offloads the context into a Python REPL environment as a variable in memory, enabling the LM to reason over its context in code and recursive LM calls, rather than purely in token space. Our results across multiple settings and models demonstrated that RLMs are an effective task-agnostic paradigm for both long-context problems and general reasoning. Building on our small fine-tuning experiments, we are excited to see future work that explicitly trains models to reason as RLMs, which could result in another axis of scale for the next generation of language model systems.

## 8. Impact Statement
This paper explores a strategy for enabling language models to solve long context problems and scaling future language model systems. The goal is to advance research on systems that can help us solve complex problems. While there are potential societal consequences of this work, we believe they are not specific to this paper and do not need to be highlighted here.

## Acknowledgments
This research is partially supported by the Laude Institute, Prime Intellect, and Modal Labs. We thank Noah Ziems, Jacob Li, James Moore, and the MIT OASYS and MIT DSG labs for insightful discussions throughout this project. We also thank Jack Cook, Matej Sirovatka, Ofir Press, Sebastian Müller, Simon Guo, and Zed Li for helpful feedback.

## References
(Selected references transcribed for context)
*   Anthropic. Claude code: Subagents. 2025.
*   Bai et al. Longbench v2. 2025.
*   Bertsch et al. Oolong. 2025.
*   Chen et al. Browsecomp-plus. 2025.
*   Hong et al. Context rot. 2025.
*   Hsieh et al. Ruler. 2024.
*   Khattab et al. Baleen. 2021.
*   OpenAI. Deep research. 2025a.
*   OpenAI. Codex cli. 2025b.
*   OpenAI, Jaech et al. Openai o1 system card. 2024.
*   Qwen Team. Qwen3-8b. 2025a.
*   Qwen Team. Qwen3-coder-480b-a35b-instruct. 2025b.
*   Singh et al. Openai gpt-5 system card. 2025.
*   Wang et al. Executable code actions elicit better llm agents (CodeAct). 2024.
*   Yang et al. Qwen3 technical report. 2025.

---

# Appendices

## A. Additional Training Details

We trained **RLM-Qwen3-8B** as a very small scale exercise in training the first natively recursive language model. We hypothesized that, though acting as an RLM appears to produce sophisticated behavior due to recursion, it can be sufficient to focus on improving the root LM’s ability to interact with the programmatic representation of the prompt in the REPL and to discern when sub-calls are useful. In other words, while a typical RLM trajectory can be extremely long due to all of the sub-calls potentially launched (possibly $\Omega(|P|)$ for a prompt $P$), the leaf sub-calls are essentially general-purpose LLM requests and the major hurdle is learning to operate as the root model.

This simple insight allowed us to explore a similarly simple recipe for training. In particular, we sampled RLM trajectories from a larger language model (Qwen3-Coder-480B-A35B-Instruct; Qwen Team 2025b) and, after filtering, distilled them to a smaller model (Qwen3-8B; Qwen Team 2025a) from the same model family. We evaluated RLM(Qwen3-Coder-480B-A35B) on 750 English LongBenchPro (Chen et al., 2026) tasks, collecting a total of 2250 candidate trajectories.

We first remove trajectories that score exactly 0.0 on the benchmark or do not go beyond one turn, bringing it down to 1,072 candidate trajectories. We separated each root RLM turn (i.e. iteration) as a separate SFT sample consisting of an input (the full history) and output (the output the root LM gave at that step).

We then applied a filtering step to remove turns beyond the context limit of Qwen3-8B (we approximated this as 100k characters), and also applied an extra programmatic correction step to fix small template mistakes in RLM usage (e.g. outputting final answers, calling the REPL, etc.). To elaborate, we noticed that trajectories generated by Qwen3-Coder-480B-A35B had noticeable mistakes in following the RLM instructions, which hurt the performance of the distilled RLM-Qwen3-8B. For example, it would often mix FINAL(answer) with FINAL(variable in REPL). We added an extra programmatic fixing step to look for common templated mistakes and patch them, leading to much better performance in the final **RLM-Qwen3-8B**. In total, 16% of turns cleaned incorrectly used FINAL answers, and 13% of turns incorrectly called a variable from the REPL (i.e. FINAL_VAR) as a final answer. In Figure 5, we show pre- and post-filtering statistics for our training trajectories.

[**Figure 5 Description:** Histograms showing RLM Turns per LongBenchPro Trajectory and RLM Tokens per Turn.
*   **Top Left (Before Filtering):** Mean turns = 5.33.
*   **Top Right (After Filtering):** Mean turns = 4.96. Distribution is tighter.
*   **Bottom Left (Before Filtering):** High count of tokens, mean output = 1032.
*   **Bottom Right (After Filtering):** Cleaned data, mean output = 910.]

We used the `prime-rl` library (Intellect, 2025) for fine-tuning. We used a batch size of 64 for 300 training steps, training for 48 H100 hours. While this exceedingly simple training recipe was able to demonstrate substantial gains for our 8B model, we call on future work to investigate training native RLMs much more thoroughly. We expect that doing so at much larger scales in terms of model size, number and variety of examples, and number of (ideally on-policy and online) rollouts will be necessary to maximize the potential of RLMs.

## B. Negative Results: Things we Tried that Did Not Work.

*   **Using the exact same RLM system prompt across all models can be problematic.** We originally wrote the RLM system prompt with in context examples for GPT-5, and tried to use the same system prompt for Qwen3-Coder, but found that it led to different, undesirable behavior in the trajectory. We had to add a small sentence to the RLM system prompt for Qwen3-Coder to prevent it from using too many recursive sub-calls.
*   **Models without sufficient coding capabilities struggle as RLMs.** Our instantiation of RLMs relies on the ability to reason through and deal with the context in a REPL environment. We found from small scale experiments that smaller models like Qwen3-8B (Yang et al., 2025) struggled without sufficient coding abilities.
*   **Thinking models without sufficient output tokens struggle as RLMs.** In addition to `Qwen3-Coder-480B-A35B-Instruct`, we also tried experimenting with `Qwen3-235B-A22B` as the RLM. While we found positive results across the board from the base model (e.g. on OOLONG (Bertsch et al., 2025), performance jumped from 30% to 38%), the smaller gap compared to the evaluated models in the main experiments (Table 1) are due to multiple trajectories running out of output tokens while producing outputs due to thinking tokens exceeding the maximum output token length of an individual LM call.
*   **RLMs without asynchronous LM calls are slow.** We implemented all sub-LM queries naively as blocking / sequential calls, which caused our RLM experiments to be slow, especially compared to just the base model. We are confident that this can be resolved with a robust implementation.
*   **Depending on the model, distinguishing between a final answer and a thought is brittle for RLMs.** The current strategy for distinguishing between a "next turn" and a final answer for the RLM is to have it wrap its answer in `FINAL()` or `FINAL_VAR()` tags. Similar to intuition about structured outputs degrading performance, we also found the model to make strange decisions (e.g. it outputs its plan as a final answer). We added minor safeguards, but we also believe this issue should be avoided altogether in the future when models are trained as RLMs.

## C. Additional Methods and Baseline Details

### C.1. Prompts for Experiments

(1a) The system prompt for **RLM with REPL** for GPT-5:

```text
You are tasked with answering a query with associated context. You can access, transform, and analyze this context interactively in a REPL environment that can recursively query sub-LLMs, which you are strongly encouraged to use as much as possible. You will be queried iteratively until you provide a final answer.

Your context is a {context_type} with {context_total_length} total characters, and is broken up into chunks of char lengths: {context_lengths}.

The REPL environment is initialized with:
1. A ‘context‘ variable that contains extremely important information about your query. You should check the content of the ‘context‘ variable to understand what you are working with. Make sure you look through it sufficiently as you answer your query.
2. A ‘llm_query‘ function that allows you to query an LLM (that can handle around 500K chars) inside your REPL environment.
3. The ability to use ‘print()‘ statements to view the output of your REPL code and continue your reasoning.

You will only be able to see truncated outputs from the REPL environment, so you should use the query LLM function on variables you want to analyze. You will find this function especially useful when you have to analyze the semantics of the context. Use these variables as buffers to build up your final answer.

Make sure to explicitly look through the entire context in REPL before answering your query. An example strategy is to first look at the context and figure out a chunking strategy, then break up the context into smart chunks, and query an LLM per chunk with a particular question and save the answers to a buffer, then query an LLM with all the buffers to produce your final answer.

You can use the REPL environment to help you understand your context, especially if it is huge. Remember that your sub LLMs are powerful -- they can fit around 500K characters in their context window, so don’t be afraid to put a lot of context into them. For example, a viable strategy is to feed 10 documents per sub-LLM query. Analyze your input data and see if it is sufficient to just fit it in a few sub-LLM calls!

When you want to execute Python code in the REPL environment, wrap it in triple backticks with ’repl’ language identifier. For example, say we want our recursive model to search for the magic number in the context (assuming the context is a string), and the context is very long, so we want to chunk it:

'''repl
chunk = context[:10000]
answer = llm_query(f"What is the magic number in the context? Here is the chunk: {{chunk}}")
print(answer)
'''

[... Additional examples omitted for brevity ...]

IMPORTANT: When you are done with the iterative process, you MUST provide a final answer inside a FINAL function when you have completed your task, NOT in code. Do not use these tags unless you have completed your task. You have two options:
1. Use FINAL(your final answer here) to provide the answer directly
2. Use FINAL_VAR(variable_name) to return a variable you have created in the REPL environment as your final output

Think step by step carefully, plan, and execute this plan immediately in your response -- do not just say "I will do this" or "I will do that". Output to the REPL environment and recursive LLMs as much as possible. Remember to explicitly answer the original query in your final answer.
```

(1b) The diff of the system prompt for **RLM with REPL (Qwen3-Coder-480B-A35B)**:
*Added line:*
`IMPORTANT: Be very careful about using ‘llm_query‘ as it incurs high runtime costs. Always batch as much information as reasonably possible into each call (aim for around ~200k characters per call). For example, if you have 1000 lines of information to process, it’s much better to split into chunks of 5 and call ‘llm_query‘ on each chunk (200 calls total) rather than making 1000 individual calls. Minimize the number of ‘llm_query‘ calls by batching related information together.`

(1c) The diff of the system prompt for **RLM (Qwen3-8B)**:
*Changes related to smaller context (32k tokens).*
`- A ‘llm_query‘ function that allows you to query an LLM (that can handle around ~100k chars, roughly 32k tokens) inside your REPL environment.`

(2) The system prompt for **RLM with REPL (no sub-calls)**:
*Similar to above, but removes `llm_query` function and examples involving sub-calls, replacing them with regex/code examples.*

(3a) The system prompt for **CodeAct with BM25** (BrowseComp+ only).
(3b) The system prompt for **CodeAct**.

### C.2. Summary agent baseline
The summarization agent baseline follows the scaffold presented in Sun et al. (2025); Wu et al. (2025); Yu et al. (2025).

## D. Additional Benchmark Details

### D.1. OOLONG-Pairs Benchmark
To create OOLONG-Pairs, we synthetically generate 20 new tasks based on the ground-truth labels for the OOLONG (Bertsch et al., 2025) `trec_coarse` split. Each question requires correctly predicting the semantic mapping for each entry. We explicitly created questions that ask for **all pairs** satisfying some properties to ensure quadratic scaling.

*   **Task 1-20:** Listed in the paper. E.g., "list all pairs of user IDs... where both users have at least one instance with a numeric value or location."

### D.2. Scaling Huge Document Corpuses in BrowseComp+
In addition to the BrowseComp+ results for $k=1000$ documents, we analyze scaling behavior.

[**Figure 6 Description:** Two plots.
*   **Left (Score vs Docs):** GPT-5 (Truncated) drops to 0% as docs increase. GPT-5 + BM25 drops significantly. RLM(GPT-5) stays near 90-100% even at 1000 docs.
*   **Right (Cost vs Docs):** RLM cost scales log-linearly. ReAct + BM25 is cheaper at low doc counts but scales similarly.
*   **Takeaway:** RLMs scale well without performance degradation.]

## E. Additional RLM Trajectories

**E.1. RLM(GPT-5) on BrowseComp-Plus-Query_74**
*   **Step 1:** GPT-5 probes with regex queries (looking for "beauty pageant", "festival").
*   **Step 2:** Finds a snippet at index 6. Launches a recursive sub-call.
*   **Step 3:** Sub-call identifies "Maria Dalmacio". Root LM verifies this with two more sub-calls and returns the final answer.
*   **Total Cost:** $0.079.

**E.2. RLM(Qwen3-Coder) on OOLONG-Pairs-Query_3**
*   **Step 1:** Probes context with code. Splits input by newlines.
*   **Step 2:** Launches sub-calls to semantically classify chunks of data (avoiding context rot).
*   **Step 3:** Uses classifications to programmatically find pairs satisfying the condition.
*   **Step 4:** Stores pairs in a variable `final_result`.
*   **Step 5:** Returns the variable.
*   **Total Cost:** $1.12.

**E.3. RLM(Qwen3-Coder) on OOLONG-Query_212**
*   **Behavior:** Qwen3-Coder is very liberal with sub-calls. It defines a function that calls `llm_query` *per line*.
*   **Step 2:** Launches a long code execution that calls the LLM thousands of times (once per line).
*   **Final:** Correctly identifies the answer programmatically.
*   **Total Cost:** $0.38 (Cost is relatively low despite many calls because each call is tiny).

**E.4. RLM(GPT-5) on CodeQA-Query_44**
*   **Task:** Identify the correct statement about a 900k token codebase.
*   **Step 1:** Model decides to partition the codebase into chunks of 380,000 chars (keeping under 500k limit) and recursively sub-query LMs to find evidence supporting or contradicting the statements.
*   **Final:** Aggregates findings and correctly identifies statement '1'.
*   **Total Cost:** $0.27.

## F. Additional Runtime and Cost Analysis of RLMs

[**Figure 7 & 8:** Runtime Quartiles for GPT-5 and Qwen3-Coder. Shows high variance.]
[**Figure 9 & 10:** Cost Histograms. Shows long-tailed distributions.]
[**Figure 11:** Average API Cost per Query vs Context Length. RLM costs scale with length and complexity but remain within acceptable bounds compared to base GPT-5.]

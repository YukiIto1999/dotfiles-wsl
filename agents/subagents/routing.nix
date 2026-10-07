{
  subagentSkills = [
    {
      subagent = "architect";
      skill = "dependency-analysis";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "description-writing";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "tech-article-reproducibility";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "explainer";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "impact-analysis";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "codebase-design";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "property-testing";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "domain-modeling";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "standard-apply";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "web-research";
      activation = "dynamic";
    }
    {
      subagent = "designer";
      skill = "browser-operation";
      activation = "dynamic";
    }
    {
      subagent = "designer";
      skill = "a11y-debugging";
      activation = "dynamic";
    }
    {
      subagent = "designer";
      skill = "browser-performance";
      activation = "dynamic";
    }
    {
      subagent = "designer";
      skill = "codebase-design";
      activation = "dynamic";
    }
    {
      subagent = "designer";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      subagent = "designer";
      skill = "ui-design";
      activation = "required";
    }
    {
      subagent = "explorer";
      skill = "dependency-analysis";
      activation = "dynamic";
    }
    {
      subagent = "explorer";
      skill = "repository-research";
      activation = "required";
    }
    {
      subagent = "implementer";
      skill = "browser-operation";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "codebase-design";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "property-testing";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "comment-writing";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "documentation-writing";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "tech-article-reproducibility";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "security-review";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "standard-apply";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "tdd";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "browser-performance";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "a11y-debugging";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "msbuild";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "run-tests";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "microbenchmarking";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "nuget-trusted-publishing";
      activation = "dynamic";
    }
    {
      subagent = "planner";
      skill = "dependency-analysis";
      activation = "dynamic";
    }
    {
      subagent = "planner";
      skill = "impact-analysis";
      activation = "dynamic";
    }
    {
      subagent = "planner";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      subagent = "planner";
      skill = "web-research";
      activation = "dynamic";
    }
    {
      subagent = "reviewer";
      skill = "code-review";
      activation = "dynamic";
    }
    {
      subagent = "reviewer";
      skill = "github-operations";
      activation = "dynamic";
    }
    {
      subagent = "reviewer";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      subagent = "reviewer";
      skill = "standard-apply";
      activation = "dynamic";
    }
    {
      subagent = "reviewer";
      skill = "standard-conformance";
      activation = "dynamic";
    }
    {
      subagent = "reviewer";
      skill = "msbuild";
      activation = "dynamic";
    }
    {
      subagent = "reviewer";
      skill = "microbenchmarking";
      activation = "dynamic";
    }
    {
      subagent = "security";
      skill = "github-operations";
      activation = "dynamic";
    }
    {
      subagent = "security";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      subagent = "security";
      skill = "security-review";
      activation = "required";
    }
  ];

  subagentHandoffs = [
    {
      from = "architect";
      to = "implementer";
      artifact = "accepted-contract";
    }
    {
      from = "architect";
      to = "planner";
      artifact = "accepted-decision-constraints";
    }
    {
      from = "designer";
      to = "implementer";
      artifact = "accepted-ui-brief";
    }
    {
      from = "designer";
      to = "planner";
      artifact = "ui-brief-dependencies";
    }
    {
      from = "explorer";
      to = "architect";
      artifact = "dependency-facts";
    }
    {
      from = "explorer";
      to = "planner";
      artifact = "repository-evidence";
    }
    {
      from = "implementer";
      to = "reviewer";
      artifact = "verified-committed-range";
    }
    {
      from = "planner";
      to = "architect";
      artifact = "unresolved-design-decision";
    }
    {
      from = "planner";
      to = "implementer";
      artifact = "accepted-plan";
    }
    {
      from = "reviewer";
      to = "implementer";
      artifact = "evidence-backed-findings";
    }
    {
      from = "reviewer";
      to = "security";
      artifact = "security-candidate-scope";
    }
    {
      from = "security";
      to = "implementer";
      artifact = "validated-finding-attack-path";
    }
  ];
}

# PowerShell Efficiency & Quality Standards

## 1. Filter Left, Format Right
*   **Source Filtering:** Always use `-Filter`, `-LdapFilter`, or `-Include` parameters at the start of a command rather than piping to `Where-Object`. 
*   **Property Selection:** Only retrieve the properties you need using `-Properties` or `-Select` to reduce the payload size over the network.

## 2. Optimized Data Handling
*   **Avoid Array Expansion:** Never use `$array += $item`. It recreates the entire array in memory. Instead, use:
    ```powershell
    $List = [System.Collections.Generic.List[object]]::new()
    $List.Add($item)
    ```
*   **Pipeline for Memory, Collections for Speed:** Use the pipeline (`|`) when processing massive datasets to keep memory low. Use `foreach ($item in $collection)` for smaller datasets where execution speed is the priority.

## 3. Toolmaking Standards
*   **Splatting:** Use HashTables for parameters to improve readability and prevent long, unmanageable code lines.
    ```powershell
    $Params = @{
        Filter     = "Enabled -eq '$true'"
        SearchBase = "OU=Users,DC=Contoso,DC=Com"
    }
    Get-ADUser @Params
    ```
*   **Structured Output:** Always return `[PSCustomObject]` instead of `Write-Host` or strings. This allows the output to be sorted, exported, or piped to other tools.

## 4. Defensive Coding
*   **Standardized Error Handling:** Wrap core logic in `try { ... } catch { ... }` blocks. Use `$PSItem.Exception.Message` to capture specific failure details.
*   **Strict Typing:** Explicitly define parameter types (e.g., `[string]`, `[int]`, `[DateTime]`) to prevent type-conversion errors.
*   **Validation:** Use `[ValidateNotNullOrEmpty()]` or `[ValidateSet()]` to catch bad data before the script logic executes.

## 5. Script Lifecycle
*   **Requires:** Use `#requires -Modules ActiveDirectory` or `#requires -RunAsAdministrator` at the top of scripts to fail fast if dependencies are missing.
*   **Cleanup:** Explicitly close sessions (e.g., `Remove-PSSession`) and clear large variables in long-running scripts.

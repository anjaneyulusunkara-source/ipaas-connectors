class CsvConnector < IPaaS::Connector::Definition
  connector '019f1ece-63b0-789a-b7e7-f91dc56619c5' do
    name 'CSV'
    avatar '/assets/icons/filetype-csv.svg'
    description <<~END_OF_DESCRIPTION
      ## Overview
      Utility connector for working with CSV content inside a runbook. It parses an in-memory CSV string, typically the output of a previous action or a small fetch, into a header row and positional data rows for follow-up steps.

      ## Actions

      ### Parse CSV
      Parses the supplied CSV `content` string into an optional `header` and positional `rows`, normalising the input to UTF-8 first. Each row is a list of string cells; ragged rows keep their own length, and blank lines are skipped.

      **Use case**: turn a CSV payload (an export, a report body, an attachment already read into a string) into structured rows a runbook can iterate over.

      #### Input Parameters

      | Parameter | Type | Required | Default | Description |
      |---|---|---|---|---|
      | `content` | String | Yes | - | The CSV text to parse |
      | `headers` | Boolean | No | `true` | Treat the first row as a header row |
      | `col_sep` | String | No | `,` | Field delimiter |
      | `quote_char` | String | No | `"` | Quote character |
      | `declared_encoding` | String | No | `UTF-8` | Fallback encoding used only when the input has no byte-order mark (e.g. `UTF-8`, `Windows-1252`) |

      #### Output

      | Field | Type | Description |
      |---|---|---|
      | `header` | String[] | The first row when `headers` is `true`; otherwise empty |
      | `rows` | Array[] | Data rows; each row is a list of string cells (positional; ragged rows preserved) |
      | `truncated` | Boolean | `true` when the file had more rows than the action returned |
      | `source_encoding` | String | The encoding detected (from a byte-order mark) or declared, used before transcoding to UTF-8 |
      | `lossy_encoding` | Boolean | `true` when transcoding replaced bytes or characters that have no UTF-8 representation |

      #### Example Input

      ```json
      {
        "content": "name,city\\nAlice,NYC\\nBob,LA\\n"
      }
      ```

      #### Example Output

      ```json
      {
        "header": ["name", "city"],
        "rows": [["Alice", "NYC"], ["Bob", "LA"]],
        "truncated": false,
        "source_encoding": "UTF-8",
        "lossy_encoding": false
      }
      ```

      #### Error Handling
      Malformed input that even liberal parsing cannot handle fails the job with a clear message, as does an invalid option (unknown `declared_encoding`, an empty `col_sep`, a multi-character `quote_char`). A row wider than 16,384 columns also fails the job; that width signals a `col_sep` that does not match the data. Ragged rows and lossy transcodes pass through: rows keep their own length, and `lossy_encoding` flags the transcode.

      #### Best Practices
      - Zip `header` with each row at the mapping layer for name-based access.
      - The action returns at most 65,536 rows (not configurable); branch on `truncated` to detect a partially-read file.
      - Check `lossy_encoding` before trusting text that may not have been UTF-8.
    END_OF_DESCRIPTION

    action '019f1ece-63b0-7d72-bdf3-3f1ee278967e' do
      name 'Parse CSV'
      avatar '/assets/icons/filetype-csv.svg'
      description <<~END_OF_DESCRIPTION
        Parses an in-memory CSV string into a `header` (optional) and positional `rows`, normalising the input to UTF-8 first. Blank lines are skipped.

        **Use case**: turn a CSV payload from an upstream action into structured rows a runbook can iterate over.

        ### Input Parameters

        | Parameter | Type | Required | Default | Description |
        |---|---|---|---|---|
        | `content` | String | Yes | - | The CSV text to parse |
        | `headers` | Boolean | No | `true` | Treat the first row as a header row |
        | `col_sep` | String | No | `,` | Field delimiter |
        | `quote_char` | String | No | `"` | Quote character |
        | `declared_encoding` | String | No | `UTF-8` | Fallback encoding used only when the input has no byte-order mark |

        ### Example Input

        ```json
        {
          "content": "name,city\\nAlice,NYC\\n"
        }
        ```

        ### Output

        | Field | Type | Description |
        |---|---|---|
        | `header` | String[] | The first row when `headers` is `true`; otherwise empty |
        | `rows` | Array[] | Data rows; each row is a list of string cells (positional; ragged rows preserved) |
        | `truncated` | Boolean | `true` when the file had more rows than the action returned |
        | `source_encoding` | String | Encoding detected or declared, used before transcoding to UTF-8 |
        | `lossy_encoding` | Boolean | `true` when transcoding replaced bytes or characters that have no UTF-8 representation |

        ### Example Output

        ```json
        {
          "header": ["name", "city"],
          "rows": [["Alice", "NYC"]],
          "truncated": false,
          "source_encoding": "UTF-8",
          "lossy_encoding": false
        }
        ```

        ### Error Handling
        Unparseable input, an invalid option (unknown `declared_encoding`, empty `col_sep`, multi-character `quote_char`), or a row wider than 16,384 columns (a sign the `col_sep` does not match the data) fails the job with a clear message. Ragged rows keep their own length; `lossy_encoding` flags a lossy transcode.

        ### Best Practices
        - Zip `header` with each row for name-based access.
        - Returns at most 65,536 rows; branch on `truncated` to detect a partially-read file.
        - Check `lossy_encoding` before trusting the text.
      END_OF_DESCRIPTION

      input_schema do
        field :content, 'CSV content', :string, required: true
        field :headers, 'First row is a header', :boolean, default: true
        field :col_sep, 'Column separator', :string, default: ','
        field :quote_char, 'Quote character', :string, default: '"'
        field :declared_encoding, 'Declared encoding', :string,
              default: 'UTF-8',
              visibility: 'optional',
              hint: 'Fallback encoding used only when the input has no byte-order mark (e.g. UTF-8, Windows-1252).'
      end

      output_schema do
        field :header, 'Header', :string, array: true
        field :rows, 'Rows', :any_item_type, array: true
        field :truncated, 'Truncated', :boolean
        field :source_encoding, 'Source encoding', :string
        field :lossy_encoding, 'Lossy encoding', :boolean
      end

      run do
        [{
          output: parse_csv(
            input[:content],
            headers: input[:headers],
            col_sep: input[:col_sep],
            quote_char: input[:quote_char],
            declared_encoding: input[:declared_encoding]
          ),
        }]
      end
    end
  end
end
